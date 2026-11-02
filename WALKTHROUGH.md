# Walkthrough (for Michael)

This guide is for preparing to talk through the project in an interview. Each section says what a file does, why it is built that way, and what you could be asked about it.

## The 30-second pitch

"I built a reproducible Metabase deployment for a fictional SaaS company. Docker Compose runs Metabase with a proper Postgres app DB and a Postgres warehouse. The warehouse has a seeded star schema and SQL views that define MRR, churn and cohorts. A Python script drives the Metabase API to create eight questions, some SQL and some GUI, plus a dashboard with one date filter wired to every card. The script then checks through the API that every card returns rows. The README also has the implementation advice I'd give a customer."

## File by file

| File | What it does | Why it is built this way |
|---|---|---|
| `docker-compose.yml` | Three services: `warehouse`, `appdb`, `metabase`. Compose project name `pf-metabase`. | A unique project name keeps containers, volumes and the network separate from other stacks on the host. Only Metabase publishes a port, and only on `127.0.0.1`. Healthchecks plus `depends_on: condition: service_healthy` make Metabase wait until both databases are ready. `mem_limit` and `-Xmx1536m` keep the stack under ~3 GB. |
| `warehouse/00-roles.sh` | Creates `metabase_reader`, a login with SELECT only and a 60 s statement timeout. | Postgres runs `/docker-entrypoint-initdb.d/*` once, in name order, on an empty data volume. It is a shell script, not SQL, so it can read the password from an env var instead of hard-coding it. `ALTER DEFAULT PRIVILEGES` covers tables that the later scripts create. |
| `warehouse/01-schema.sql` | Tables `plans`, `customers`, `subscriptions`, `invoices`, `product_events`, `support_tickets`, with FKs and CHECKs. | Metabase reads the FKs during sync and uses them for implicit joins in the GUI. A subscription row is one period at a fixed price, so upgrades and downgrades are visible as new rows. |
| `warehouse/02-seed.sql` | Generates the data in pure SQL. | `setseed(0.42)` makes `random()` repeatable. Temp tables hold a hidden `health` score per customer, which drives churn (geometric lifetime), expansion, usage and tickets. Lifetime in months is `floor(ln(1-u)/ln(1-p))`: inverse-transform sampling of a geometric distribution. |
| `warehouse/03-indexes-views.sql` | Indexes and the three views. | Indexes are created after the bulk load because that is faster. Each index matches a dashboard filter or join. The views hold the metric definitions in one place. |
| `provision.py` | Runs setup, then: login, add database (with sync schedules), wait for sync and FK detection, collection, 8 cards, dashboard, verify. | It uses `urllib` only, so there is nothing to `pip install` on the server. Cards and the dashboard are matched by name, so re-runs update instead of duplicating. The dashboard `PUT` replaces the full set of dashcards, so the layout always converges to what the code describes. |
| `Makefile` | `deploy`, `provision`, `verify`, `tunnel`, `status`, `logs`, `down`, `reset`, `screenshot`. | Every Docker command runs over `ssh myserver`, so nothing runs in Docker on the laptop. `reset` asks for confirmation because it deletes volumes. |
| `scripts/screenshot.mjs` | Logs in through the API, sets the session cookie in headless Chrome and saves a PNG. | It uses the Chrome DevTools protocol over Node 22's built-in WebSocket, so Puppeteer isn't needed. |
| `.env.example` | Lists every setting. | Real values go in `.env`, which is git-ignored. |

## Concepts to be able to explain

- **MRR bridge**: this month's MRR = last month's MRR + new + expansion - contraction - churned. The `monthly_mrr` view compares each customer's month-end MRR with the previous month's using `lag()`.
- **Logo churn vs. revenue churn**: logo churn is the share of *customers* lost; revenue churn is the share of *MRR* lost. SMB churn moves logo churn more, while one lost Enterprise account moves revenue churn more.
- **NRR vs. GRR**: NRR = MRR now from the accounts that existed N months ago, divided by their MRR then; expansion can push it above 100%. GRR caps each account at its starting MRR, so it measures only losses. A 3-month window is used because there are only 12 months of data; the usual measure is 12-month NRR.
- **Cohort retention**: group customers by signup month and track the share still paying after N months. A triangle-shaped table is expected, because newer cohorts have fewer months of history.
- **Field filter vs. text variable**: a field filter is bound to a column. Metabase writes the WHERE clause, supports every date widget option, and replaces an empty filter with `1=1`. A plain `{{variable}}` is just a substituted value.

## Likely interview questions and suggested answers

1. **Why not let Metabase use H2?** "H2 is a single embedded file. It can corrupt on an unclean shutdown, it's awkward to back up, and only one Metabase instance can use it. Postgres lets me `pg_dump` all the content, roll back a failed upgrade and run several instances. Metabase's own docs recommend this for production."
2. **A customer says their dashboard is slow. How do you troubleshoot it?** "First find out which card is slow; the query timing is in the network tab or the logs. Take that card's SQL (View the SQL) and run `EXPLAIN ANALYZE` on the warehouse. Usually the cause is a missing index on a filter column, a filter that isn't pushed down, or a heavy view computed on every load. Fix it in the warehouse (index, materialize, pre-aggregate), then add caching. Last, check Metabase itself: JVM heap, the app DB, and the number of cards that load at once."
3. **Filter dropdown values are stale or missing. Why?** "Field values come from the scan job, not the sync job. Check the database's scan schedule, whether the field is set to 'list' or 'search', and run 'Re-scan field values'. High-cardinality columns default to search boxes on purpose."
4. **Someone added a column and it doesn't show up.** "Metadata sync hasn't run yet. Trigger 'Sync database schema now', or check that the Metabase DB user can see the column. A missing GRANT often looks exactly like a sync problem."
5. **How does your date filter work across SQL and GUI questions?** "The dashboard has one `date/all-options` parameter. SQL cards declare `{{date_range}}` as a field filter on a real column, and the parameter maps to that template tag. GUI cards map the parameter directly to a column. Field filters render with the fully qualified table name, so they can't target an aliased table; the NRR query filters months in an unaliased CTE for that reason."
6. **How would you stop users in tenant A from seeing tenant B's rows?** "Group-based permissions plus data sandboxing, which is row-level filtering by a user attribute and needs Pro/Enterprise. On OSS, use separate connections or schemas per tenant with database users that can only see their own data. And never give tenant users native SQL access to shared tables, because SQL bypasses sandboxes."
7. **How did you size memory?** "The host has 7.6 GB and already runs other services. Metabase's heap is capped at 1.5 GB, and the container limit is 2.25 GB, because the JVM also needs metaspace, thread stacks and off-heap memory. A heap-sized container limit gets the process OOM-killed. The two Postgres containers are small. Observed use is about 1.65 GB for Metabase."
8. **Is provision.py idempotent?** "Mostly. Setup is skipped once an admin exists. The database, collection, cards and dashboard are looked up by name and updated. The dashboard PUT replaces all dashcards, so the layout converges. It isn't a full reconciler: if I rename a card in code, the old card stays behind."
9. **Why both SQL and GUI questions?** "SQL handles logic the GUI can't express cleanly, like the NRR self-join or the cohort pivot. GUI questions are what most customers' business users build, and they keep drill-through. The implicit join on 'Top 10 accounts' works only because the schema declares foreign keys. That is useful advice when a customer's GUI joins don't appear."
10. **How would you upgrade Metabase safely?** "Read the release notes, dump the app DB, change the pinned tag, `compose up`, and watch the migration logs. If something breaks, restore the dump and go back to the old tag. Migrations only run forward, so the dump is the rollback plan."
11. **Why is the data synthetic, and how is it realistic?** "It's deterministic: a fixed seed in SQL. A hidden health score per account drives churn, usage, expansion and tickets, so the dashboard shows real-looking relationships: churn rises with tickets per month, usage falls before churn, and older cohorts decay."
12. **How would this scale to a real company?** "Move the metric views into dbt and materialize them on a schedule. Run the warehouse on a managed service, put Metabase behind TLS and SSO, use a managed Postgres for the app DB, run more than one Metabase instance behind a load balancer, and set caching per dashboard."

## Try it yourself

1. `make tunnel`, log in, open the dashboard and change **Date range** to "Previous 3 months". Note which cards change and which stay put.
2. Open "MRR trend", click the **SQL** icon and remove `WHERE {{date_range}}`. The card no longer reacts to the dashboard filter. Then undo the change.
3. In the NRR card, change the self-join to use `customer_monthly_mrr` as the field-filter table *with* an alias, and watch the error. That error is the field-filter gotcha.
4. On the server, run `EXPLAIN ANALYZE` on the "Top 10 accounts" SQL (shown under "View the SQL") with and without `product_events_time_idx` (`DROP INDEX` / re-run `03-indexes-views.sql`, then `make reset` to restore).
5. Make a GUI question: count of support tickets by category, filtered to `priority = urgent`. Save it and add it to the dashboard, mapping the date filter to `opened_at`.
6. Connect with `docker compose exec warehouse psql -U metabase_reader -d saas` and try an `INSERT`. Explain the error.
7. Change `JAVA_OPTS` to `-Xmx512m`, redeploy and watch `make status` and `make logs`. Then put it back.
8. Run `make provision` twice and confirm it reports "updated" rather than "created" the second time.
9. In Admin > Databases > Acme Cloud warehouse, look at the sync and scan schedules that `provision.py` set.
10. Create a Model from `monthly_mrr`, give `mrr` the Currency semantic type, and rebuild "MRR movements" on the Model.
