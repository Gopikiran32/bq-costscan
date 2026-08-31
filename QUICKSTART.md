# Quickstart

From repo link to a list of things to fix. About 15 minutes, most of it waiting
for one query.

You need: access to a BigQuery project, and a browser. Nothing to install.

---

## 1 — Get the files

**Download the ZIP** (easiest): on the repo page, green **Code** button →
**Download ZIP** → unzip it.

**Or clone:**

```bash
git clone https://github.com/YOUR_USERNAME/bq-costscan.git
cd bq-costscan
```

You need two files out of it:

```
scan/costscan_project_v2.sql    the scan
site/index.html                 the report
```

---

## 2 — Check you have the permissions

On each project you want to scan:

```
roles/bigquery.resourceViewer    job history
roles/bigquery.metadataViewer    storage bytes and dataset options
roles/bigquery.jobUser           on the one project you run the query from
```

No organization-level access needed. A project owner can grant these. If you're
missing `metadataViewer` the scan still runs — you just lose the storage
recommendations, and the report tells you which projects were affected rather
than quietly dropping them.

To check quickly, run this in the console (set location first — see step 4):

```sql
SELECT COUNT(*) FROM `region-eu`.INFORMATION_SCHEMA.JOBS_BY_PROJECT
WHERE creation_time >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 1 DAY);
```

A number back means you're fine.

---

## 3 — Edit the settings

Open `scan/costscan_project_v2.sql` in any text editor. The block at the top is
the only thing you change:

```sql
DECLARE bq_region        STRING        DEFAULT 'region-eu';
DECLARE window_days      INT64         DEFAULT 30;
DECLARE target_projects  ARRAY<STRING> DEFAULT [];
DECLARE recent_days      INT64         DEFAULT 1;
DECLARE price_per_tib    FLOAT64       DEFAULT 6.25;
DECLARE price_per_slot   FLOAT64       DEFAULT 0.06;
```

| Setting | What to put |
|---|---|
| `bq_region` | `region-eu`, `region-us`, or a single region like `region-europe-west3` |
| `window_days` | 30 is a good default. 7 for a quick look. |
| `target_projects` | See below. Empty `[]` scans only the project you run from. |
| `recent_days` | How recently a workload must have run to appear in the action list |
| `price_per_tib` / `price_per_slot` | Your negotiated rates if you have them; defaults are EU list |

**On `target_projects`** — list **every project that runs queries and every
project that holds tables**. Those are usually different: job history lives where
a query was submitted, storage lives where the tables are. Missing one
undercounts silently.

```sql
DECLARE target_projects ARRAY<STRING> DEFAULT [
  'my-bi-prod',       -- runs dbt
  'my-ai-prod',       -- runs scheduled queries
  'my-data-raw'       -- holds the raw tables
];
```

---

## 4 — Set the query location

**This is the step everyone forgets.** Skip it and you get
`Table ... was not found in location US`.

In the BigQuery console: **More → Query settings → Data location →** pick your
region → **Save**.

It has to match `bq_region`. `region-eu` means *European Union (EU)*.

---

## 5 — Run it

Paste the whole file into the query editor. It's a script, so it runs as one
statement — don't split it up.

Click **Run**. Takes roughly a minute depending on how many projects you listed.

---

## 6 — Save the result

You get **one row with one column**. Click the cell to expand it if you want to
see what's in there.

Then **Save results → JSON**. That downloads the file you need.

---

## 7 — Open the report

Open `site/index.html` in a browser. Double-click it — `file://` works fine,
there's no server.

Drop the JSON file onto the page, or paste the cell contents into the text box.

Nothing is uploaded. The page has no backend. If you want to confirm, open
DevTools → Network before you drop the file; you'll see no outbound request.

---

## 8 — Read it in this order

**First, two sanity checks** near the top of the JSON:

- `reconciliation.ratio` — the per-second timeline and the job records measure
  the same slot-hours two different ways. Near `1.0` means the demand chart is
  trustworthy. Well above it means something is double-counting, and the report
  shows a red banner rather than a confident chart.
- `projects_skipped` — anything here was inaccessible and is excluded, so your
  real numbers are larger than shown.

**Then the report itself:**

1. **Headline** — estimated recoverable over 12 months.
2. **Findings** — ranked by annual impact. Red ones are money being lost right
   now, and they're usually the cheapest to fix.
3. **Slot demand by hour** — average sizes a baseline, p95 sizes a ceiling. Hours
   are UTC.
4. **Storage** — both billing models priced per dataset, with the action needed.
5. **Top 25 workloads** — the work queue.

---

## 9 — Act on the CSV

**Download CSV** on the workloads section. Columns, in order:

```
source_type, workload_id, destination_table, project_id,
current_lane, recommended_lane, change_needed, annual_saving_if_moved, ...
```

Sorted by saving. Open it, read the top five rows, and you have your morning.

Start with the largest single row rather than the easiest — the arithmetic is the
same either way, and one visible win buys you room to do the rest.

---

## Common problems

| What you see | Why | Fix |
|---|---|---|
| `Table ... not found in location US` | Location not set | Step 4 |
| `Access Denied ... organization level` | Wrong file | Use `costscan_project_v2.sql`, not v1 |
| Everything shows `UNKNOWN` billing | `SCHEMATA_OPTIONS` unreadable | Grant `metadataViewer`; absent usually means the LOGICAL default |
| Report says "that doesn't look like a scan result" | Wrong part of the output copied | Use **Save results → JSON** instead of copy-paste |
| Demand chart looks far too high | Peak is the max over the whole window, not yesterday | Check `busiest_minute` and `reconciliation.ratio` |
| Workloads list is empty | Nothing ran within `recent_days`, or nothing is mislaned | Raise `recent_days` to 7 |

---

## What it never does

- Does not store or transmit query text. Text is read inside BigQuery to compute
  counts and is never emitted.
- Does not read table data. Metadata views only.
- Does not write anything outside temporary session tables.
- Hashes principal identities with SHA-256 before they leave the query.

The SQL is short enough to audit. Read it before you run it — that's the point.
