/*
================================================================
OLIST ANALYSIS
Question: Do bad reviews come from SLOW deliveries or from MISSED
delivery estimates, and does either one stop customers from
buying again?
================================================================

STEP 2: BASELINE (learn the data)
  Q1  Order status counts           -> which orders to analyze
  Q2  Date range                    -> time window for all numbers
  Q3  Orders, revenue, avg order    -> size of the business
  Q4  % of delivered orders late    -> how common is lateness
  Q5  Review score distribution     -> how common are bad reviews
  Q6  % of customers who reorder    -> how big is the repeat group

STEP 3: RETENTION
  Q7  Repeat rate by first-purchase month (cohorts)

STEP 4: THE ANSWER
  Q8  Avg review: late vs. on time
  Q9  Avg review by days late (on time / 1-3 / 4-7 / 8+)
  Q10 Avg review by total delivery time, for ON-TIME orders only
      -> isolates "slow" from "broken promise"
  Q11 Repeat rate: first order late vs. on time
  Q12 Late rate by seller state / category -> where to fix
  */

  
--Query 1: order status counts
SELECT order_status, COUNT(*) AS order_count,
ROUND(COUNT(*) * 100.0 / (SELECT COUNT(*) FROM orders), 1) AS pct_of_orders
FROM orders
GROUP BY order_status
ORDER BY order_count DESC;

--Query 2: date range
SELECT MIN(order_purchase_timestamp) AS first_order,
       MAX(order_purchase_timestamp) AS last_order
FROM orders;
--Query 3: orders, revenue, average order value
--Revenue = item prices (excludes shipping). COUNT(DISTINCT) because one order can have several item rows.
SELECT COUNT(DISTINCT order_id) AS total_orders,
       SUM(price) AS total_revenue,
       ROUND(SUM(price) / COUNT(DISTINCT order_id), 2) AS avg_order_value
FROM order_items;


--SETUP (run once): reusable view of delivered orders with lateness and review score
--A view is a saved query you can treat like a table. Every query below uses it.
--Dates are compared with ::date (day only), because estimated dates have no time of day.
--Orders with multiple reviews get their average score.
CREATE OR REPLACE VIEW delivered_orders AS
SELECT o.order_id,
       c.customer_unique_id,
       c.customer_state,
       o.order_purchase_timestamp,
       o.order_delivered_customer_date::date - o.order_purchase_timestamp::date      AS delivery_days,
       o.order_delivered_customer_date::date - o.order_estimated_delivery_date::date AS days_late,
       CASE WHEN o.order_delivered_customer_date::date > o.order_estimated_delivery_date::date
            THEN 1 ELSE 0 END AS is_late,
       r.review_score
FROM orders o
JOIN customers c ON o.customer_id = c.customer_id
LEFT JOIN (SELECT order_id, AVG(review_score) AS review_score
           FROM order_reviews
           GROUP BY order_id) r ON o.order_id = r.order_id
WHERE o.order_status = 'delivered'
  AND o.order_delivered_customer_date IS NOT NULL;


--Query 4: % of delivered orders that arrived late
--AVG of a 1/0 column = the share of 1s, so 100 * AVG(is_late) = % late.
SELECT COUNT(*) AS delivered_orders,
       SUM(is_late) AS late_orders,
       ROUND(100.0 * AVG(is_late), 1) AS pct_late
FROM delivered_orders;


--Query 5a: review score distribution
--SUM(COUNT(*)) OVER () is a window function: the grand total across all groups.
SELECT review_score,
       COUNT(*) AS reviews,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct_of_reviews
FROM order_reviews
GROUP BY review_score
ORDER BY review_score;

--Query 5b: average review score
SELECT ROUND(AVG(review_score), 2) AS avg_review
FROM order_reviews;


--Query 6: % of customers who ordered more than once
--Uses customer_unique_id (the real person), not customer_id (new for every order).
--A CTE (WITH ...) builds a temporary table, then the main query reads from it.
WITH customer_orders AS (
    SELECT customer_unique_id, COUNT(*) AS n_orders
    FROM delivered_orders
    GROUP BY customer_unique_id
)
SELECT COUNT(*) AS customers,
       SUM(CASE WHEN n_orders > 1 THEN 1 ELSE 0 END) AS repeat_customers,
       ROUND(100.0 * AVG(CASE WHEN n_orders > 1 THEN 1 ELSE 0 END), 2) AS pct_repeat
FROM customer_orders;


--Query 7: repeat rate by first-purchase month (cohorts)
--Expect later cohorts to look worse: they had less time left in the data to return.
WITH first_orders AS (
    SELECT customer_unique_id,
           MIN(order_purchase_timestamp) AS first_purchase,
           COUNT(*) AS n_orders
    FROM delivered_orders
    GROUP BY customer_unique_id
)
SELECT DATE_TRUNC('month', first_purchase)::date AS cohort_month,
       COUNT(*) AS customers,
       SUM(CASE WHEN n_orders > 1 THEN 1 ELSE 0 END) AS repeat_customers,
       ROUND(100.0 * AVG(CASE WHEN n_orders > 1 THEN 1 ELSE 0 END), 2) AS pct_repeat
FROM first_orders
GROUP BY cohort_month
ORDER BY cohort_month;


--Query 8: review score, late vs. on time
--pct_bad_reviews = share of orders scored 1 or 2 stars.
SELECT CASE WHEN is_late = 1 THEN 'late' ELSE 'on time' END AS delivery,
       COUNT(*) AS orders,
       ROUND(AVG(review_score), 2) AS avg_review,
       ROUND(100.0 * AVG(CASE WHEN review_score <= 2 THEN 1 ELSE 0 END), 1) AS pct_bad_reviews
FROM delivered_orders
WHERE review_score IS NOT NULL
GROUP BY delivery;


--Query 9: review score by how late
--Does it get worse the later it is? The number prefixes keep the buckets in order.
SELECT CASE WHEN days_late <= 0 THEN '1. on time'
            WHEN days_late <= 3 THEN '2. 1-3 days late'
            WHEN days_late <= 7 THEN '3. 4-7 days late'
            ELSE '4. 8+ days late' END AS lateness,
       COUNT(*) AS orders,
       ROUND(AVG(review_score), 2) AS avg_review,
       ROUND(100.0 * AVG(CASE WHEN review_score <= 2 THEN 1 ELSE 0 END), 1) AS pct_bad_reviews
FROM delivered_orders
WHERE review_score IS NOT NULL
GROUP BY lateness
ORDER BY lateness;


--Query 10: KEY QUERY - slow vs. broken promise
--ON-TIME orders only, grouped by total delivery time.
--If reviews stay high even for slow on-time orders, the problem is broken promises, not speed.
SELECT CASE WHEN delivery_days <= 7  THEN '1. 0-7 days'
            WHEN delivery_days <= 14 THEN '2. 8-14 days'
            WHEN delivery_days <= 21 THEN '3. 15-21 days'
            ELSE '4. 22+ days' END AS delivery_time,
       COUNT(*) AS orders,
       ROUND(AVG(review_score), 2) AS avg_review,
       ROUND(100.0 * AVG(CASE WHEN review_score <= 2 THEN 1 ELSE 0 END), 1) AS pct_bad_reviews
FROM delivered_orders
WHERE is_late = 0
  AND review_score IS NOT NULL
GROUP BY delivery_time
ORDER BY delivery_time;


--Query 11: repeat rate, first order late vs. on time
--ROW_NUMBER() numbers each customer's orders by date, so order_num = 1 is their first.
--Only first orders before Mar 2018, so every customer had at least ~6 months to return.
WITH ranked AS (
    SELECT customer_unique_id,
           is_late,
           order_purchase_timestamp,
           ROW_NUMBER() OVER (PARTITION BY customer_unique_id
                              ORDER BY order_purchase_timestamp) AS order_num,
           COUNT(*) OVER (PARTITION BY customer_unique_id) AS total_orders
    FROM delivered_orders
)
SELECT CASE WHEN is_late = 1 THEN 'first order late' ELSE 'first order on time' END AS first_order,
       COUNT(*) AS customers,
       SUM(CASE WHEN total_orders > 1 THEN 1 ELSE 0 END) AS came_back,
       ROUND(100.0 * AVG(CASE WHEN total_orders > 1 THEN 1 ELSE 0 END), 2) AS pct_came_back
FROM ranked
WHERE order_num = 1
  AND order_purchase_timestamp < '2018-03-01'
GROUP BY first_order;


--Query 12a: where is lateness worst? By customer state
--HAVING filters groups after GROUP BY; it drops tiny states with unreliable %.
SELECT customer_state,
       COUNT(*) AS orders,
       ROUND(100.0 * AVG(is_late), 1) AS pct_late,
       ROUND(AVG(review_score), 2) AS avg_review
FROM delivered_orders
GROUP BY customer_state
HAVING COUNT(*) >= 500
ORDER BY pct_late DESC;


--Query 12b: where is lateness worst? By product category
--DISTINCT order/category pairs so orders with many items aren't counted multiple times.
WITH order_category AS (
    SELECT DISTINCT oi.order_id,
           COALESCE(t.product_category_name_english, p.product_category_name, 'unknown') AS category
    FROM order_items oi
    JOIN products p ON oi.product_id = p.product_id
    LEFT JOIN product_category_name_translation t
           ON p.product_category_name = t.product_category_name
)
SELECT oc.category,
       COUNT(*) AS orders,
       ROUND(100.0 * AVG(d.is_late), 1) AS pct_late,
       ROUND(AVG(d.review_score), 2) AS avg_review
FROM order_category oc
JOIN delivered_orders d ON oc.order_id = d.order_id
GROUP BY oc.category
HAVING COUNT(*) >= 500
ORDER BY pct_late DESC;