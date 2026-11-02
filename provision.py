#!/usr/bin/env python3
"""Provision Metabase through its REST API: admin user, warehouse connection, questions, dashboard.

Stdlib only (urllib), so it runs on any host with python3 >= 3.8 and no pip install.
Idempotent: re-running updates the existing questions/dashboard by name instead of duplicating them.

    python3 provision.py                # provision, then verify
    python3 provision.py --verify-only  # only check the dashboard and that every card returns rows

Settings come from environment variables, or from a .env file next to this script.
"""

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))

DB_NAME = "Acme Cloud warehouse"
COLLECTION_NAME = "Acme Cloud - SaaS metrics"
DASHBOARD_NAME = "SaaS health overview"
DATE_PARAM = {
    "id": "date_range",
    "name": "Date range",
    "slug": "date_range",
    "type": "date/all-options",
    "sectionId": "date",
}
WAREHOUSE_TABLES = [
    "customers", "subscriptions", "invoices", "product_events", "support_tickets", "plans",
    "customer_monthly_mrr", "monthly_mrr", "cohort_retention",
]
FUNNEL_STEPS = ["signed_up", "connected_data_source", "created_dashboard", "invited_teammate", "scheduled_report"]


# --------------------------------------------------------------------------- config / HTTP helpers

def load_env_file(path):
    """Minimal .env reader: KEY=VALUE lines; real environment variables win."""
    if not os.path.exists(path):
        return
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            os.environ.setdefault(key.strip(), value.strip().strip('"').strip("'"))


def env(name, default=None):
    value = os.environ.get(name, default)
    if value is None:
        sys.exit(f"Missing required setting {name} (set it in .env or the environment)")
    return value


class Metabase:
    def __init__(self, base_url):
        self.base = base_url.rstrip("/")
        self.session = None

    def call(self, method, path, body=None, timeout=120):
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(self.base + path, data=data, method=method)
        req.add_header("Content-Type", "application/json")
        if self.session:
            req.add_header("X-Metabase-Session", self.session)
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                raw = resp.read()
        except urllib.error.HTTPError as err:
            detail = err.read().decode(errors="replace")[:800]
            raise RuntimeError(f"{method} {path} -> HTTP {err.code}: {detail}") from None
        return json.loads(raw) if raw else None

    get = lambda self, p: self.call("GET", p)
    post = lambda self, p, b=None: self.call("POST", p, b if b is not None else {})
    put = lambda self, p, b: self.call("PUT", p, b)


def log(msg):
    print(f"[provision] {msg}", flush=True)


# --------------------------------------------------------------------------- steps

def wait_until_healthy(mb, timeout_s=600):
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        try:
            if mb.get("/api/health").get("status") == "ok":
                return
        except Exception:  # connection refused while the JVM starts
            pass
        time.sleep(5)
    sys.exit("Metabase did not become healthy in time")


def setup_and_login(mb):
    email, password = env("MB_ADMIN_EMAIL"), env("MB_ADMIN_PASSWORD")
    props = mb.get("/api/session/properties")
    if not props.get("has-user-setup"):
        log("first run: creating admin user via /api/setup")
        mb.post("/api/setup", {
            "token": props["setup-token"],
            "user": {
                "email": email,
                "password": password,
                "first_name": env("MB_ADMIN_FIRST_NAME", "Admin"),
                "last_name": env("MB_ADMIN_LAST_NAME", "User"),
            },
            "prefs": {"site_name": "Acme Cloud Analytics", "site_locale": "en"},
        })
    else:
        log("setup already done, logging in")
    mb.session = mb.post("/api/session", {"username": email, "password": password})["id"]


def find_database(mb):
    existing = [d["id"] for d in mb.get("/api/database")["data"] if d["name"] == DB_NAME]
    return existing[0] if existing else None


def ensure_database(mb):
    db_id = find_database(mb)
    if db_id:
        log(f"warehouse already connected (database id {db_id})")
    else:
        log("connecting warehouse as read-only role metabase_reader")
        db_id = mb.post("/api/database", {
            "engine": "postgres",
            "name": DB_NAME,
            "details": {
                "host": "warehouse",          # compose service name, resolved on the pf-metabase network
                "port": 5432,
                "dbname": "saas",
                "user": "metabase_reader",
                "password": env("WAREHOUSE_READER_PASSWORD"),
                "ssl": False,
                "schema-filters-type": "inclusion",
                "schema-filters-patterns": "public",
                "let-user-control-scheduling": True,
            },
            # Schema changes are rare in a warehouse: sync metadata hourly instead of the default,
            # and refresh filter dropdown values nightly at 02:00 instead of on every sync.
            "schedules": {
                "metadata_sync": {"schedule_type": "hourly", "schedule_minute": 15},
                "cache_field_values": {"schedule_type": "daily", "schedule_hour": 2, "schedule_minute": 0},
            },
        })["id"]
    mb.post(f"/api/database/{db_id}/sync_schema")
    return db_id


def wait_for_metadata(mb, db_id, timeout_s=300):
    """Block until sync has discovered every table/view and its columns; return name lookups."""
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        meta = mb.get(f"/api/database/{db_id}/metadata")
        tables = {t["name"]: t for t in meta["tables"]}
        if all(name in tables and tables[name]["fields"] for name in WAREHOUSE_TABLES):
            fields = {(t["name"], f["name"]): f["id"] for t in meta["tables"] for f in t["fields"]}
            fk_ready = mb.get(f"/api/field/{fields[('product_events', 'customer_id')]}").get("fk_target_field_id")
            if fk_ready:
                return {n: t["id"] for n, t in tables.items()}, fields
        time.sleep(3)
    sys.exit("Warehouse sync did not finish in time")


def find_collection(mb):
    for c in mb.get("/api/collection"):
        if c.get("name") == COLLECTION_NAME and not c.get("archived"):
            return c["id"]
    return None


def ensure_collection(mb):
    return find_collection(mb) or mb.post("/api/collection", {"name": COLLECTION_NAME,
                                        "description": "Provisioned by provision.py"})["id"]


def collection_items(mb, coll_id, model):
    items = mb.get(f"/api/collection/{coll_id}/items?models={model}")
    items = items["data"] if isinstance(items, dict) else items
    return {i["name"]: i["id"] for i in items}


# --------------------------------------------------------------------------- question definitions

def currency(*cols):
    return {"column_settings": {json.dumps(["name", c]): {"number_style": "currency", "currency": "USD",
                                                          "decimals": 0} for c in cols}}


def native(db_id, sql, filter_field_id):
    """Native SQL question with a {{date_range}} *field filter* bound to a real column.

    A field filter (type "dimension") lets the dashboard's date widget drive the SQL; Metabase
    replaces {{date_range}} with a WHERE clause on that column, or with 1=1 when no value is set.
    """
    tag = {
        "id": str(uuid.uuid5(uuid.NAMESPACE_URL, f"date_range-{filter_field_id}")),
        "name": "date_range",
        "display-name": "Date range",
        "type": "dimension",
        "dimension": ["field", filter_field_id, None],
        "widget-type": "date/all-options",
    }
    return {"type": "native", "database": db_id,
            "native": {"query": sql.strip(), "template-tags": {"date_range": tag}}}


def mbql(db_id, query):
    return {"type": "query", "database": db_id, "query": query}


def question_specs(db_id, t, f):
    """Return the 8 questions. Each has a dashboard filter target and a layout slot (col, row, w, h)."""
    tag_target = ["dimension", ["template-tag", "date_range"]]
    field_target = lambda tbl, col: ["dimension", ["field", f[(tbl, col)], None]]

    return [
        {
            "name": "MRR trend",
            "description": "Month-end MRR and paying customers (view: monthly_mrr).",
            "display": "line",
            "dataset_query": native(db_id, """
SELECT month, mrr, active_customers
FROM monthly_mrr
WHERE {{date_range}}
ORDER BY month
""", f[("monthly_mrr", "month")]),
            "visualization_settings": {"graph.dimensions": ["month"], "graph.metrics": ["mrr"],
                                       "graph.show_values": False, **currency("mrr")},
            "target": tag_target, "layout": (0, 2, 12, 6),
        },
        {
            "name": "MRR movements (new / expansion / contraction / churn)",
            "description": "GUI question on the monthly_mrr view: where MRR growth comes from.",
            "display": "bar",
            "dataset_query": mbql(db_id, {
                "source-table": t["monthly_mrr"],
                "aggregation": [["sum", ["field", f[("monthly_mrr", c)], None]]
                                for c in ("new_mrr", "expansion_mrr", "contraction_mrr", "churned_mrr")],
                "breakout": [["field", f[("monthly_mrr", "month")], {"temporal-unit": "month"}]],
            }),
            "visualization_settings": {
                "stackable.stack_type": "stacked",
                # MBQL names repeated aggregations sum, sum_2, ... in the order given above
                "series_settings": {"sum": {"title": "New", "color": "#84BB4C"},
                                    "sum_2": {"title": "Expansion", "color": "#98D9D9"},
                                    "sum_3": {"title": "Contraction", "color": "#F9CF48"},
                                    "sum_4": {"title": "Churned", "color": "#ED6E6E"}},
            },
            "target": field_target("monthly_mrr", "month"), "layout": (12, 2, 12, 6),
        },
        {
            "name": "Churn rate (logo and revenue)",
            "description": "Monthly % of customers lost and % of starting MRR lost to churn.",
            "display": "line",
            "dataset_query": native(db_id, """
SELECT month,
       round(100.0 * churned_customers / NULLIF(customers_at_start, 0), 2) AS logo_churn_pct,
       round(-100.0 * churned_mrr / NULLIF(mrr_at_start, 0), 2)           AS revenue_churn_pct
FROM monthly_mrr
WHERE {{date_range}}
  AND customers_at_start > 0
ORDER BY month
""", f[("monthly_mrr", "month")]),
            "visualization_settings": {"graph.dimensions": ["month"],
                                       "graph.metrics": ["logo_churn_pct", "revenue_churn_pct"]},
            "target": tag_target, "layout": (0, 8, 12, 6),
        },
        {
            "name": "Net revenue retention (trailing 3 months)",
            "description": "MRR today from accounts that were paying 3 months ago, divided by their MRR "
                           "then. NRR > 100% means expansion outweighs churn. GRR caps each account at "
                           "its starting MRR.",
            "display": "line",
            # Field filters render as "public"."monthly_mrr"."month", so they cannot target an aliased
            # table. Filtering a CTE that reads the table unaliased keeps the self-join below free to alias.
            "dataset_query": native(db_id, """
WITH selected_months AS (
    SELECT month FROM monthly_mrr WHERE {{date_range}}
)
SELECT cur.month,
       round(100.0 * sum(cur.mrr) / sum(base.mrr), 1)                 AS nrr_pct,
       round(100.0 * sum(LEAST(cur.mrr, base.mrr)) / sum(base.mrr), 1) AS grr_pct
FROM customer_monthly_mrr AS base
JOIN customer_monthly_mrr AS cur
  ON cur.customer_id = base.customer_id
 AND cur.month = (base.month + INTERVAL '3 months')::date
WHERE base.mrr > 0
  AND cur.month IN (SELECT month FROM selected_months)
GROUP BY cur.month
ORDER BY cur.month
""", f[("monthly_mrr", "month")]),
            "visualization_settings": {"graph.dimensions": ["month"], "graph.metrics": ["nrr_pct", "grr_pct"],
                                       "graph.y_axis.auto_range": False, "graph.y_axis.min": 80,
                                       "graph.y_axis.max": 110},
            "target": tag_target, "layout": (12, 8, 12, 6),
        },
        {
            "name": "Cohort retention (logo, % still paying)",
            "description": "Rows = signup month, columns = months since signup (view: cohort_retention). "
                           "The date filter selects which cohorts to show.",
            "display": "table",
            "dataset_query": native(db_id, "\n".join([
                "SELECT to_char(cohort_month, 'YYYY-MM') AS cohort,",
                "       max(cohort_size_in_month) FILTER (WHERE months_since_signup = 0) AS customers,",
                *[f"       max(retention_pct) FILTER (WHERE months_since_signup = {m}) AS \"M{m}\"{',' if m < 11 else ''}"
                  for m in range(1, 12)],
                "FROM cohort_retention",
                "WHERE {{date_range}}",
                "GROUP BY cohort_month",
                "ORDER BY cohort_month",
            ]), f[("cohort_retention", "cohort_month")]),
            "visualization_settings": {"table.column_formatting": [{
                "columns": [f"M{m}" for m in range(1, 12)], "type": "range",
                "colors": ["#ED6E6E", "#FFFFFF", "#84BB4C"], "min_type": "custom", "min_value": 60,
                "max_type": "custom", "max_value": 100, "highlight_row": False,
            }]},
            "target": tag_target, "layout": (0, 14, 24, 7),
        },
        {
            "name": "Ticket volume vs. churn",
            "description": "Accounts bucketed by support tickets per paying month; churn % per bucket. "
                           "The date filter limits which tickets are counted.",
            "display": "bar",
            "dataset_query": native(db_id, """
WITH tickets AS (
    SELECT customer_id, count(*) AS tickets
    FROM support_tickets
    WHERE {{date_range}}
    GROUP BY customer_id
), accounts AS (
    SELECT cm.customer_id,
           COALESCE(max(t.tickets), 0)::numeric / NULLIF(count(*) FILTER (WHERE cm.mrr > 0), 0) AS tickets_per_month,
           EXISTS (SELECT 1 FROM subscriptions s
                   WHERE s.customer_id = cm.customer_id AND s.end_reason = 'churned') AS churned
    FROM customer_monthly_mrr cm
    LEFT JOIN tickets t ON t.customer_id = cm.customer_id
    GROUP BY cm.customer_id
)
SELECT CASE WHEN tickets_per_month = 0   THEN '0'
            WHEN tickets_per_month < 0.5 THEN '0 - 0.5'
            WHEN tickets_per_month < 1   THEN '0.5 - 1'
            WHEN tickets_per_month < 2   THEN '1 - 2'
            ELSE '2+' END                         AS tickets_per_month,
       count(*)                                   AS accounts,
       round(100.0 * avg(churned::int), 1)        AS churn_pct
FROM accounts
WHERE tickets_per_month IS NOT NULL
GROUP BY 1
ORDER BY min(tickets_per_month)
""", f[("support_tickets", "opened_at")]),
            "visualization_settings": {"graph.dimensions": ["tickets_per_month"], "graph.metrics": ["churn_pct"],
                                       "graph.show_values": True, "graph.x_axis.title_text": "Tickets per paying month",
                                       "graph.y_axis.title_text": "Churned accounts %"},
            "target": tag_target, "layout": (0, 21, 12, 7),
        },
        {
            "name": "Onboarding funnel",
            "description": "GUI question: distinct accounts reaching each onboarding step.",
            "display": "funnel",
            "dataset_query": mbql(db_id, {
                "source-table": t["product_events"],
                "filter": ["=", ["field", f[("product_events", "event_type")], None], *FUNNEL_STEPS],
                "aggregation": [["distinct", ["field", f[("product_events", "customer_id")], None]]],
                "breakout": [["field", f[("product_events", "event_type")], None]],
                "order-by": [["desc", ["aggregation", 0]]],
            }),
            "visualization_settings": {},
            "target": field_target("product_events", "occurred_at"), "layout": (0, 28, 24, 6),
        },
        {
            "name": "Top 10 accounts by product usage",
            "description": "GUI question with an implicit join (product_events.customer_id -> customers) "
                           "that Metabase builds from the foreign key it found during sync.",
            "display": "row",
            "dataset_query": mbql(db_id, {
                "source-table": t["product_events"],
                "filter": ["=", ["field", f[("product_events", "event_type")], None],
                           "dashboard_viewed", "question_run"],
                "aggregation": [["count"]],
                "breakout": [["field", f[("customers", "company_name")],
                              {"source-field": f[("product_events", "customer_id")]}]],
                "order-by": [["desc", ["aggregation", 0]]],
                "limit": 10,
            }),
            "visualization_settings": {"graph.show_values": True},
            "target": field_target("product_events", "occurred_at"), "layout": (12, 21, 12, 7),
        },
    ]


INTRO_TEXT = (
    "## Acme Cloud: SaaS health\n"
    "Synthetic B2B SaaS data (Nov 2025 to Oct 2026). Use **Date range** to narrow every card. "
    "SQL questions use field filters; GUI questions map the filter to a date column. "
    "Definitions live in the warehouse views `monthly_mrr`, `customer_monthly_mrr` and `cohort_retention`."
)


# --------------------------------------------------------------------------- cards + dashboard

def upsert_cards(mb, coll_id, specs):
    existing = collection_items(mb, coll_id, "card")
    for spec in specs:
        body = {k: spec[k] for k in ("name", "description", "display", "dataset_query", "visualization_settings")}
        body["collection_id"] = coll_id
        if spec["name"] in existing:
            spec["card_id"] = existing[spec["name"]]
            mb.put(f"/api/card/{spec['card_id']}", body)
            log(f"updated question  #{spec['card_id']:<4} {spec['name']}")
        else:
            spec["card_id"] = mb.post("/api/card", body)["id"]
            log(f"created question  #{spec['card_id']:<4} {spec['name']}")


def upsert_dashboard(mb, coll_id, specs):
    existing = collection_items(mb, coll_id, "dashboard")
    if DASHBOARD_NAME in existing:
        dash_id = existing[DASHBOARD_NAME]
    else:
        dash_id = mb.post("/api/dashboard", {"name": DASHBOARD_NAME, "collection_id": coll_id})["id"]

    dashcards = [{
        "id": -1, "card_id": None, "row": 0, "col": 0, "size_x": 24, "size_y": 2,
        "parameter_mappings": [],
        "visualization_settings": {"virtual_card": {"name": None, "display": "text", "archived": False,
                                                    "dataset_query": {}, "visualization_settings": {}},
                                   "text": INTRO_TEXT},
    }]
    for i, spec in enumerate(specs, start=2):
        col, row, w, h = spec["layout"]
        dashcards.append({
            "id": -i, "card_id": spec["card_id"], "row": row, "col": col, "size_x": w, "size_y": h,
            "visualization_settings": {},
            "parameter_mappings": [{"parameter_id": DATE_PARAM["id"], "card_id": spec["card_id"],
                                    "target": spec["target"]}],
        })
    # PUT replaces the full set of dashcards, so re-runs converge to exactly this layout.
    mb.put(f"/api/dashboard/{dash_id}", {
        "description": "Provisioned by provision.py: MRR, churn, NRR, cohorts, support and usage.",
        "parameters": [DATE_PARAM],
        "dashcards": dashcards,
        "width": "full",
    })
    log(f"dashboard #{dash_id} '{DASHBOARD_NAME}' has {len(specs)} questions + intro text")
    return dash_id


# --------------------------------------------------------------------------- verification

def run_dashcard(mb, dash_id, dc, value=None):
    params = []
    if value is not None:
        params = [{"id": DATE_PARAM["id"], "type": DATE_PARAM["type"], "value": value,
                   "target": dc["parameter_mappings"][0]["target"]}]
    res = mb.call("POST", f"/api/dashboard/{dash_id}/dashcard/{dc['id']}/card/{dc['card_id']}/query",
                  {"parameters": params}, timeout=180)
    if res.get("status") != "completed":
        raise RuntimeError(f"{res.get('status')}: {res.get('error')}")
    return len(res["data"]["rows"])


def verify(mb, expected_names):
    coll_id = find_collection(mb)
    dashboards = collection_items(mb, coll_id, "dashboard") if coll_id else {}
    if DASHBOARD_NAME not in dashboards:
        sys.exit("VERIFY FAILED: dashboard not found")
    dash = mb.get(f"/api/dashboard/{dashboards[DASHBOARD_NAME]}")
    cards = [dc for dc in dash["dashcards"] if dc.get("card_id")]
    names = {dc["card"]["name"] for dc in cards}
    missing = set(expected_names) - names
    ok = not missing
    if missing:
        print(f"  MISSING cards: {sorted(missing)}")
    print(f"\nDashboard #{dash['id']} '{dash['name']}': {len(cards)} question cards, "
          f"parameters={[p['slug'] for p in dash['parameters']]}")
    print(f"  {'question':<56} {'mapped':>6} {'rows':>5} {'rows(Apr-Oct 26)':>17}")
    for dc in sorted(cards, key=lambda d: (d["row"], d["col"])):
        mapped = bool(dc["parameter_mappings"])
        try:
            # filtered first: Metabase remembers a user's last-used filter value, so end unfiltered
            filtered = run_dashcard(mb, dash["id"], dc, "2026-04-01~2026-10-31")
            all_rows = run_dashcard(mb, dash["id"], dc)
        except RuntimeError as err:
            ok = False
            print(f"  {dc['card']['name']:<56} ERROR {err}")
            continue
        ok &= mapped and all_rows > 0 and filtered > 0
        print(f"  {dc['card']['name']:<56} {str(mapped):>6} {all_rows:>5} {filtered:>17}")
    print("\nVERIFY " + ("PASSED" if ok else "FAILED"))
    return ok


# --------------------------------------------------------------------------- main

def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--verify-only", action="store_true", help="skip provisioning, only verify")
    args = parser.parse_args()

    load_env_file(os.path.join(HERE, ".env"))
    mb = Metabase(env("MB_URL", "http://127.0.0.1:3300"))
    wait_until_healthy(mb)
    setup_and_login(mb)

    db_id = find_database(mb) if args.verify_only else ensure_database(mb)
    if not db_id:
        sys.exit("VERIFY FAILED: warehouse database is not connected in Metabase")
    tables, fields = wait_for_metadata(mb, db_id)
    specs = question_specs(db_id, tables, fields)

    if not args.verify_only:
        coll_id = ensure_collection(mb)
        upsert_cards(mb, coll_id, specs)
        upsert_dashboard(mb, coll_id, specs)

    sys.exit(0 if verify(mb, [s["name"] for s in specs]) else 1)


if __name__ == "__main__":
    main()
