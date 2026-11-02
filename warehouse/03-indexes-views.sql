-- Indexes are created after the bulk load (faster than maintaining them row by row during seeding).
-- Each one matches a filter or join the dashboard actually does.

CREATE INDEX subscriptions_customer_idx   ON subscriptions (customer_id);
CREATE INDEX subscriptions_period_idx     ON subscriptions (started_at, ended_at);
CREATE INDEX invoices_customer_idx        ON invoices (customer_id);
CREATE INDEX invoices_date_idx            ON invoices (invoice_date);
-- product_events is the big table: dashboard filters by date, groups by account and event type.
CREATE INDEX product_events_time_idx      ON product_events (occurred_at);
CREATE INDEX product_events_cust_type_idx ON product_events (customer_id, event_type);
CREATE INDEX support_tickets_cust_idx     ON support_tickets (customer_id);
CREATE INDEX support_tickets_opened_idx   ON support_tickets (opened_at);
CREATE INDEX customers_signup_idx         ON customers (signup_date);

-- ------------------------------------------------------------------------------------------
-- customer_monthly_mrr: one row per customer per month, MRR held at month end (0 if not subscribed).
-- The building block for MRR movements, churn, NRR and cohorts.
CREATE VIEW customer_monthly_mrr AS
WITH months AS (
    SELECT generate_series(date_trunc('month', min(started_at)),
                           date_trunc('month', (SELECT max(invoice_date) FROM invoices)),
                           INTERVAL '1 month')::date AS month
    FROM subscriptions
)
SELECT m.month,
       c.customer_id,
       COALESCE(sum(s.mrr), 0)::numeric(12,2) AS mrr
FROM months m
JOIN customers c
  ON c.signup_date < m.month + INTERVAL '1 month'             -- only months after signup
LEFT JOIN subscriptions s
  ON s.customer_id = c.customer_id
 AND s.started_at  <  m.month + INTERVAL '1 month'             -- started on/before month end
 AND (s.ended_at IS NULL OR s.ended_at >= m.month + INTERVAL '1 month')  -- still running at month end
GROUP BY m.month, c.customer_id;

COMMENT ON VIEW customer_monthly_mrr IS 'MRR per customer at each month end (0 = not subscribed).';

-- ------------------------------------------------------------------------------------------
-- monthly_mrr: the classic SaaS MRR bridge. mrr(month) = mrr(prev) + new + expansion + contraction + churned.
CREATE VIEW monthly_mrr AS
WITH cm AS (
    SELECT month, customer_id, mrr,
           lag(mrr, 1, 0) OVER (PARTITION BY customer_id ORDER BY month) AS prev_mrr
    FROM customer_monthly_mrr
)
SELECT month,
       sum(mrr)                                                               AS mrr,
       count(*) FILTER (WHERE mrr > 0)                                        AS active_customers,
       count(*) FILTER (WHERE prev_mrr > 0)                                   AS customers_at_start,
       count(*) FILTER (WHERE prev_mrr > 0 AND mrr = 0)                       AS churned_customers,
       COALESCE(sum(mrr)            FILTER (WHERE prev_mrr = 0 AND mrr > 0), 0)          AS new_mrr,
       COALESCE(sum(mrr - prev_mrr) FILTER (WHERE prev_mrr > 0 AND mrr > prev_mrr), 0)   AS expansion_mrr,
       COALESCE(sum(mrr - prev_mrr) FILTER (WHERE mrr > 0 AND mrr < prev_mrr), 0)        AS contraction_mrr,
       COALESCE(-sum(prev_mrr)      FILTER (WHERE prev_mrr > 0 AND mrr = 0), 0)          AS churned_mrr,
       sum(prev_mrr)                                                          AS mrr_at_start
FROM cm
GROUP BY month;

COMMENT ON VIEW monthly_mrr IS 'Month-end MRR with new / expansion / contraction / churn movements.';

-- ------------------------------------------------------------------------------------------
-- cohort_retention: logo retention by signup-month cohort (long format: cohort x months since signup).
CREATE VIEW cohort_retention AS
WITH cohorts AS (
    SELECT customer_id, date_trunc('month', signup_date)::date AS cohort_month
    FROM customers
)
SELECT co.cohort_month,
       ((extract(year FROM cm.month) - extract(year FROM co.cohort_month)) * 12
        + extract(month FROM cm.month) - extract(month FROM co.cohort_month))::int AS months_since_signup,
       count(DISTINCT co.customer_id)                                              AS cohort_size_in_month,
       count(DISTINCT co.customer_id) FILTER (WHERE cm.mrr > 0)                    AS retained_customers,
       round(100.0 * count(DISTINCT co.customer_id) FILTER (WHERE cm.mrr > 0)
                   / count(DISTINCT co.customer_id), 1)                            AS retention_pct
FROM cohorts co
JOIN customer_monthly_mrr cm USING (customer_id)
GROUP BY 1, 2;

COMMENT ON VIEW cohort_retention IS 'Share of each signup cohort still paying N months later.';
