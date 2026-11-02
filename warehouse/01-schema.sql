-- Warehouse schema for "Acme Cloud", a fictional B2B SaaS company that sells a per-seat analytics product.
-- Star-ish layout: two small dimensions (plans, customers) and four fact tables keyed to customers.
-- Foreign keys are declared on purpose: Metabase reads them during sync and uses them for
-- implicit joins in the GUI query builder (e.g. "Product events -> Customer -> Company name").

CREATE TABLE plans (
    plan_id         smallint PRIMARY KEY,
    plan_name       text    NOT NULL UNIQUE,
    price_per_seat  numeric(10,2) NOT NULL
);

CREATE TABLE customers (
    customer_id     integer PRIMARY KEY,
    company_name    text    NOT NULL,
    industry        text    NOT NULL,
    country         text    NOT NULL,
    segment         text    NOT NULL CHECK (segment IN ('SMB', 'Mid-Market', 'Enterprise')),
    employees       integer NOT NULL,
    signup_date     date    NOT NULL
);

-- One row per contiguous period at a given plan/seat count.
-- An upgrade or downgrade closes the current row and opens a new one; churn closes it with no successor.
CREATE TABLE subscriptions (
    subscription_id integer PRIMARY KEY,
    customer_id     integer NOT NULL REFERENCES customers (customer_id),
    plan_id         smallint NOT NULL REFERENCES plans (plan_id),
    seats           integer NOT NULL,
    mrr             numeric(12,2) NOT NULL,
    started_at      date    NOT NULL,
    ended_at        date,              -- NULL = still active
    end_reason      text CHECK (end_reason IN ('churned', 'expansion', 'contraction'))
);

CREATE TABLE invoices (
    invoice_id      integer PRIMARY KEY,
    customer_id     integer NOT NULL REFERENCES customers (customer_id),
    subscription_id integer NOT NULL REFERENCES subscriptions (subscription_id),
    invoice_date    date    NOT NULL,
    amount          numeric(12,2) NOT NULL,
    status          text    NOT NULL CHECK (status IN ('paid', 'failed', 'refunded'))
);

CREATE TABLE product_events (
    event_id        bigint  PRIMARY KEY,
    customer_id     integer NOT NULL REFERENCES customers (customer_id),
    user_id         integer NOT NULL,
    event_type      text    NOT NULL,
    occurred_at     timestamptz NOT NULL
);

CREATE TABLE support_tickets (
    ticket_id       integer PRIMARY KEY,
    customer_id     integer NOT NULL REFERENCES customers (customer_id),
    opened_at       timestamptz NOT NULL,
    resolved_at     timestamptz,
    priority        text    NOT NULL CHECK (priority IN ('low', 'normal', 'high', 'urgent')),
    category        text    NOT NULL,
    csat_score      smallint CHECK (csat_score BETWEEN 1 AND 5)
);

COMMENT ON TABLE customers       IS 'One row per paying account (company).';
COMMENT ON TABLE subscriptions   IS 'Subscription periods; MRR = seats x plan price at the time.';
COMMENT ON TABLE invoices        IS 'Monthly invoices generated from subscriptions.';
COMMENT ON TABLE product_events  IS 'In-app activity: onboarding funnel steps plus ongoing usage.';
COMMENT ON TABLE support_tickets IS 'Support desk tickets per account.';
