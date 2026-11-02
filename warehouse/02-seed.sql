-- Deterministic synthetic data: 12 months (2025-11-01 .. 2026-10-31), ~900 customers.
-- Pure SQL (generate_series + random()); setseed() makes every rebuild produce identical numbers.
--
-- Each customer gets a hidden "health" score (0..1) that is NOT stored in the warehouse.
-- It drives churn, expansion, product usage and ticket volume, so the dashboards
-- show the correlations a real SaaS business would see (unhealthy accounts file more
-- tickets, use the product less, and churn more).

SELECT setseed(0.42);

INSERT INTO plans VALUES (1, 'Starter', 12), (2, 'Growth', 25), (3, 'Enterprise', 45);

-- ---------------------------------------------------------------- customers
CREATE TEMP TABLE _rand AS
SELECT id                                   AS customer_id,
       random() AS health, random() AS r_plan, random() AS r_seats, random() AS r_signup,
       random() AS r_life, random() AS r_change, random() AS r_change_at, random() AS r_mult,
       random() AS r_ind,  random() AS r_country,
       random() AS f1, random() AS f2, random() AS f3, random() AS f4
FROM generate_series(1, 900) AS id;

CREATE TEMP TABLE _cust AS
SELECT r.*,
       p.plan_id,
       CASE p.plan_id WHEN 1 THEN 2  + floor(r.r_seats * 9)
                      WHEN 2 THEN 8  + floor(r.r_seats * 33)
                      ELSE        30 + floor(r.r_seats * r.r_seats * 170) END::int  AS seats,
       -- 120-account launch cohort in the first two weeks, then signups skewed towards later months (growth)
       CASE WHEN r.customer_id <= 120
            THEN DATE '2025-11-01' + floor(r.r_signup * 14)::int
            ELSE DATE '2025-11-01' + floor(power(r.r_signup, 0.75) * 364)::int END AS signup_date,
       -- monthly churn probability by plan, scaled 0.4x (healthy) .. 1.8x (unhealthy)
       CASE p.plan_id WHEN 1 THEN 0.050 WHEN 2 THEN 0.028 ELSE 0.012 END
           * (1.8 - 1.4 * r.health)                                               AS churn_p
FROM _rand r
CROSS JOIN LATERAL (SELECT CASE WHEN r.r_plan < 0.55 THEN 1 WHEN r.r_plan < 0.88 THEN 2 ELSE 3 END AS plan_id) p;

ALTER TABLE _cust ADD COLUMN churned_at date, ADD COLUMN change_kind text, ADD COLUMN change_at date,
                  ADD COLUMN new_plan_id smallint, ADD COLUMN new_seats int;

-- Lifetime in months ~ geometric(churn_p); customer churns at the renewal after that many months.
UPDATE _cust SET churned_at = NULLIF(
    LEAST(signup_date + (floor(ln(1 - r_life) / ln(1 - churn_p)) + 1)::int * INTERVAL '1 month',
          DATE '2026-11-01')::date,
    DATE '2026-11-01');

-- Healthy accounts sometimes expand (more seats, Starter may upgrade to Growth); unhealthy ones may contract.
UPDATE _cust SET
    change_kind = CASE WHEN health > 0.55 AND r_change < 0.40 THEN 'expansion'
                       WHEN health < 0.35 AND r_change < 0.25 THEN 'contraction' END,
    change_at   = signup_date + (2 + floor(r_change_at * 6))::int * INTERVAL '1 month';
UPDATE _cust SET change_kind = NULL
 WHERE change_at > DATE '2026-10-31' OR change_at >= COALESCE(churned_at, DATE '2026-11-01');
UPDATE _cust SET
    new_seats   = CASE change_kind WHEN 'expansion' THEN ceil(seats * (1.3 + 0.7 * r_mult))
                                   ELSE greatest(1, floor(seats * (0.5 + 0.2 * r_mult))) END,
    new_plan_id = CASE WHEN change_kind = 'expansion' AND plan_id = 1 AND r_mult > 0.5 THEN 2 ELSE plan_id END
 WHERE change_kind IS NOT NULL;

INSERT INTO customers (customer_id, company_name, industry, country, segment, employees, signup_date)
SELECT customer_id,
       (ARRAY['Northwind','Bluefin','Copperleaf','Driftwood','Evergreen','Foxglove','Granite','Harbor',
              'Ironbark','Juniper','Kestrel','Lumen','Meridian','Nimbus','Orchid','Pinnacle','Quartz',
              'Redwood','Saffron','Tidewater','Umbra','Vantage','Willow','Xenon','Yarrow','Zephyr',
              'Atlas','Beacon','Cobalt','Delta'])[(customer_id - 1) % 30 + 1]
       || ' ' ||
       (ARRAY['Labs','Logistics','Health','Retail','Systems','Foods','Capital','Media','Energy',
              'Robotics','Travel','Analytics','Studios','Freight','Insurance','Learning','Pharma',
              'Networks','Apparel','Security','Farms','Motors','Bank','Games','Realty','Telecom',
              'Clinics','Outdoors','Payments','Works'])[((customer_id - 1) / 30) % 30 + 1],
       (ARRAY['Software','Retail','Healthcare','Financial Services','Logistics','Education',
              'Manufacturing','Media'])[1 + floor(r_ind * 8)::int],
       (ARRAY['United States','United States','United States','United Kingdom','Germany','Indonesia',
              'Singapore','Australia','Brazil','India'])[1 + floor(r_country * 10)::int],
       CASE plan_id WHEN 1 THEN 'SMB' WHEN 2 THEN 'Mid-Market' ELSE 'Enterprise' END,
       seats * (8 + floor(r_seats * 20))::int,
       signup_date
FROM _cust;

-- ---------------------------------------------------------------- subscriptions
INSERT INTO subscriptions (subscription_id, customer_id, plan_id, seats, mrr, started_at, ended_at, end_reason)
SELECT row_number() OVER (ORDER BY customer_id, started_at), *
FROM (
    -- first (or only) period
    SELECT c.customer_id, c.plan_id, c.seats, c.seats * p.price_per_seat AS mrr,
           c.signup_date AS started_at,
           CASE WHEN c.change_kind IS NOT NULL THEN c.change_at ELSE c.churned_at END AS ended_at,
           CASE WHEN c.change_kind IS NOT NULL THEN c.change_kind
                WHEN c.churned_at IS NOT NULL THEN 'churned' END AS end_reason
    FROM _cust c JOIN plans p USING (plan_id)
    UNION ALL
    -- period after an expansion / contraction
    SELECT c.customer_id, c.new_plan_id, c.new_seats, c.new_seats * p.price_per_seat,
           c.change_at, c.churned_at,
           CASE WHEN c.churned_at IS NOT NULL THEN 'churned' END
    FROM _cust c JOIN plans p ON p.plan_id = c.new_plan_id
    WHERE c.change_kind IS NOT NULL
) s;

-- ---------------------------------------------------------------- invoices (monthly, in advance)
INSERT INTO invoices (invoice_id, customer_id, subscription_id, invoice_date, amount, status)
SELECT row_number() OVER (ORDER BY s.subscription_id, d), s.customer_id, s.subscription_id, d::date, s.mrr,
       CASE WHEN random() < 0.025 THEN 'failed' WHEN random() < 0.01 THEN 'refunded' ELSE 'paid' END
FROM subscriptions s
CROSS JOIN LATERAL generate_series(s.started_at, COALESCE(s.ended_at, DATE '2026-11-01') - 1, INTERVAL '1 month') d;

-- ---------------------------------------------------------------- product events
CREATE SEQUENCE _event_id;

-- 1) Onboarding funnel: every account signs up; deeper steps are likelier for healthy accounts.
WITH depth AS (
    SELECT customer_id, signup_date, health,
           1 + (f1 < 0.92)::int * (1 + (f2 < 0.50 + 0.45 * health)::int
                                * (1 + (f3 < 0.45 + 0.45 * health)::int
                                * (1 + (f4 < 0.35 + 0.45 * health)::int))) AS steps
    FROM _cust
)
INSERT INTO product_events (event_id, customer_id, user_id, event_type, occurred_at)
SELECT nextval('_event_id'), d.customer_id, d.customer_id * 1000,
       (ARRAY['signed_up','connected_data_source','created_dashboard','invited_teammate','scheduled_report'])[n],
       d.signup_date + (n - 1) * INTERVAL '2 days' + random() * INTERVAL '2 days'
FROM depth d
CROSS JOIN LATERAL generate_series(1, d.steps) n
ORDER BY d.customer_id, n;

-- 2) Ongoing weekly usage while subscribed. Usage drops in the ~8 weeks before an account churns.
INSERT INTO product_events (event_id, customer_id, user_id, event_type, occurred_at)
SELECT nextval('_event_id'), w.customer_id,
       w.customer_id * 1000 + floor(random() * w.seats)::int,
       CASE WHEN random() < 0.7 THEN 'dashboard_viewed' ELSE 'question_run' END,
       w.week_start + random() * INTERVAL '7 days'
FROM (
    SELECT c.customer_id, c.seats, wk AS week_start,
           floor(random() * c.seats * (0.2 + 0.8 * c.health)
                 * CASE WHEN c.churned_at IS NOT NULL AND wk > c.churned_at - INTERVAL '8 weeks' THEN 0.35 ELSE 1 END
           )::int AS n_events
    FROM _cust c
    CROSS JOIN LATERAL generate_series(c.signup_date + 7,
                                       LEAST(COALESCE(c.churned_at, DATE '2026-10-31'), DATE '2026-10-31') - 7,
                                       INTERVAL '1 week') wk
) w
CROSS JOIN LATERAL generate_series(1, w.n_events);

-- ---------------------------------------------------------------- support tickets
INSERT INTO support_tickets (ticket_id, customer_id, opened_at, resolved_at, priority, category, csat_score)
SELECT row_number() OVER (ORDER BY t.opened_at, t.customer_id),
       t.customer_id, t.opened_at,
       t.opened_at + (CASE t.priority WHEN 'urgent' THEN 4 WHEN 'high' THEN 12 WHEN 'normal' THEN 30 ELSE 72 END
                      * (0.3 + random() * 1.7)) * INTERVAL '1 hour',
       t.priority, t.category,
       CASE WHEN random() < 0.4 THEN NULL
            ELSE greatest(1, least(5, round(1.5 + 3.5 * t.health + (random() - 0.5) * 1.5)))::smallint END
FROM (
    SELECT c.customer_id, c.health,
           m + random() * INTERVAL '28 days' AS opened_at,
           (ARRAY['low','normal','normal','normal','high','high','urgent'])[1 + floor(random() * 7)::int] AS priority,
           (ARRAY['how-to','how-to','bug','data-connection','performance','billing','feature-request'])
               [1 + floor(random() * 7)::int] AS category
    FROM _cust c
    CROSS JOIN LATERAL generate_series(c.signup_date,
                                       LEAST(COALESCE(c.churned_at, DATE '2026-10-31'), DATE '2026-10-31') - 1,
                                       INTERVAL '1 month') m
    -- 0..N tickets per active month; N grows sharply as health falls, and a little with account size
    CROSS JOIN LATERAL generate_series(1, floor(power(random(), 1.5)
                                         * (0.3 + 5.0 * power(1 - c.health, 2))
                                         * CASE WHEN c.seats > 40 THEN 1.2 ELSE 1 END)::int)
) t;

-- Late-window signups can have onboarding steps that fall after the data cut-off; drop those.
DELETE FROM product_events WHERE occurred_at >= TIMESTAMPTZ '2026-11-01 00:00:00+00';

DROP SEQUENCE _event_id;
ANALYZE;
