# bq-costscan

A read-only BigQuery cost scan. Run one SQL file in your own console, drop the
result into a web page, get a ranked list of what's costing you money and what to
change.

**Nothing is uploaded.** No agent, no service account, no access granted to
anyone. The SQL runs in your project; the report renders in your browser.

---

**New here?** [QUICKSTART.md](QUICKSTART.md) walks through it start to finish.

## How it works

| Step | What you do | What you get |
|---|---|---|
| 1 | Run [`scan/costscan_project_v2.sql`](scan/costscan_project_v2.sql) in your BigQuery console | One row, one JSON column |
| 2 | Drop that result onto the report page | Ranked findings, priced both ways |
| 3 | Download the CSV | A work queue sorted by monthly saving |

---

## What it looks at

- **Billing lane** — every dbt model and scheduled query priced on on-demand *and*
  on capacity, so you can see which side of the break-even each one falls on.
  Both directions are reported: compute-heavy work is usually cheaper left on
  on-demand, because on-demand doesn't bill compute at all.
- **Storage billing** — logical versus physical per dataset, with a churn guard.
  Datasets already on physical that are costing more for it get flagged to switch
  back.
- **Slot demand** — per-minute, rolled up by hour. The average divides by every
  minute including idle ones, because averaging only over busy minutes is the
  standard way to oversize a reservation baseline.
- **Query antipatterns** — `SELECT *`, cross joins, unbounded sorts, long runners.

---

## What it does not do

- Does not store or transmit query text. Text is read inside BigQuery to compute
  counts and is never emitted.
- Does not read table data. Metadata views only.
- Does not write anything outside temporary session tables.
- Hashes principal identities with SHA-256 before they leave the query, so the
  report shows who is expensive without showing who they are.

Read the SQL before you run it. It's deliberately short enough to audit, and the
header comment states every one of these guarantees in the file itself.

---

## Permissions

Per project you want covered:

```
roles/bigquery.resourceViewer    job history
roles/bigquery.metadataViewer    storage bytes and dataset options
roles/bigquery.jobUser           on the one project you run the query from
```

No organization-level IAM required. A project owner can grant these without
involving an org admin.

---

## Running the scan

**1. Set the processing location** to match your data, or you'll get
`Table ... was not found in location US`. This is the step everyone forgets.

In the BigQuery console: **More → Query settings → Data location →** pick your
region (e.g. *European Union (EU)*) **→ Save**.

**2. Edit the DECLARE block** at the top of the file:

```sql
DECLARE bq_region        STRING       DEFAULT 'region-eu';
DECLARE window_days      INT64        DEFAULT 30;
DECLARE target_projects  ARRAY<STRING> DEFAULT [];   -- empty = current project
DECLARE recent_days      INT64        DEFAULT 1;     -- workload list window
DECLARE price_per_tib    FLOAT64      DEFAULT 6.25;  -- your negotiated rate
DECLARE price_per_slot   FLOAT64      DEFAULT 0.06;
```

`target_projects` should list **every project that runs queries and every project
that holds tables** — those are usually different. Job history lives where a query
was submitted; storage lives where the tables are. Missing one silently
undercounts rather than warning you.

**3. Run it.** Paste the whole file into the query editor — it's a script and
runs as a single statement. Takes about a minute.

**4. Save the result.** You get one row with one column. Click the cell to expand
it, or use **Save results → JSON** to download it directly.

**5. Open the report** — `site/index.html` — and drop the file in.

<details>
<summary>Prefer the command line?</summary>

```bash
bq query --location=EU --use_legacy_sql=false --format=prettyjson \
  < scan/costscan_project_v2.sql > scan_result.json
```

The console is the recommended path. Reading the SQL before running it is the
point, and the editor puts it in front of you.
</details>

---

## Reading the output

Two fields to check before trusting anything else:

- **`reconciliation.ratio`** — the per-second timeline and the job records measure
  the same slot-hours by different routes. Near `1.0` means the demand chart is
  sound. Materially above it means the timeline is double-counting, and the report
  will say so rather than drawing a confident chart.
- **`projects_skipped`** — anything listed here was inaccessible and is excluded,
  so the real numbers are larger than what's shown.

Prices default to EU list rates. If you have negotiated rates, put them in the
DECLARE block before quoting any figure to anyone.

---

## Troubleshooting

| Error | Cause | Fix |
|---|---|---|
| `Table ... not found in location US` | Processing location doesn't match `bq_region` | Set query location to EU (or your region) |
| `Access Denied ... at the organization level` | Using an org-scoped view | This version is project-scoped; make sure you're on `costscan_project_v2.sql` |
| `Unrecognized name: query` | `JOBS_BY_ORGANIZATION` has no query text by design | Project-scoped views do expose it |
| `Unrecognized name: autoscale_max_slots` | `autoscale` is a STRUCT | Use `autoscale.max_slots`; reservations with `scaling_mode` put the cap in top-level `max_slots` |
| Everything shows `UNKNOWN` billing model | `SCHEMATA_OPTIONS` only lists explicitly-set options | Grant `metadataViewer`; absent means the LOGICAL default |
| Demand chart looks far too high | Peak is the max over the whole window, not yesterday | Check `busiest_minute` and `reconciliation.ratio` |

---

## Deploying the report page

`site/index.html` is a single self-contained file with no build step and no
backend. Open it locally (`file://` works fine), or deploy it:

```bash
npm install -g wrangler
wrangler login
wrangler deploy
```

`wrangler.jsonc` serves the `site/` directory as static assets. There is no build
command. To deploy automatically on push instead, connect the repo under
**Workers & Pages → Create → Workers → Connect to Git** and leave the build
command empty.

---

## Accuracy notes

- Capacity estimates apply a **1.2× autoscale multiplier** for overprovisioning.
  Real-world overhead ranges roughly 5–25%; adjust if you've measured yours.
- Per-principal savings assume an all-or-nothing lane switch. In practice a
  principal's jobs split across both lanes, so treat those as an upper bound.
- Workload classification uses the full window; the displayed list is filtered to
  recent runs. One day is too thin a sample to classify a lane on.

---

## Contact

Built by Gopi Kiran Gogineni. If you want the findings implemented rather than
just listed, get in touch through the report page.

## License

MIT — see [LICENSE](LICENSE).
