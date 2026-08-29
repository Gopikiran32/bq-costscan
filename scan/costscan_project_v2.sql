-- ============================================================================
--  BigQuery cost scan  ·  v2  ·  PROJECT-SCOPED  ·  READ-ONLY
-- ============================================================================
--
--  WHY PROJECT-SCOPED
--    The organization-level INFORMATION_SCHEMA views need org-wide IAM that
--    most people cannot grant themselves. This version reads one or more
--    projects individually, so a data engineer with normal project access can
--    run it without waiting on an org admin.
--
--  WHAT THIS DOES
--    Reads BigQuery metadata and returns ONE row with ONE JSON column
--    summarising your compute and storage cost profile.
--
--  WHAT IT DOES NOT DO
--    - Does not store or transmit any query text. Query text is read only to
--      compute counts, inside the database, and is never emitted.
--    - Does not read table data. Metadata views only.
--    - Does not write anything outside temporary session tables.
--    - Principal identities are SHA-256 hashed before leaving this query.
--
--  WHAT YOU NEED  (per project listed below)
--    roles/bigquery.resourceViewer   on each project   -- job history
--    roles/bigquery.metadataViewer   on each project   -- storage bytes
--    roles/bigquery.jobUser          on the project you run from
--
--  HOW TO RUN
--    0. Set the query PROCESSING LOCATION to match bq_region, or you will get
--       "Table ... was not found in location US".
--         Console: More -> Query settings -> Data location
--         CLI:     bq query --location=EU --use_legacy_sql=false < this_file.sql
--    1. Set the DECLAREs below. Put every project you want covered in
--       target_projects, or leave it empty to scan only the current project.
--    2. Paste the whole file into the BigQuery console and run.
--    3. Copy the single result cell, or use "Save results -> JSON".
--
--  Projects that fail (no access, wrong region) are skipped and reported in
--  the output rather than failing the whole scan.
-- ============================================================================

-- ---------------------------------------------------------------- settings --
DECLARE bq_region       STRING  DEFAULT 'region-eu';
DECLARE window_days     INT64   DEFAULT 30;
DECLARE price_per_tib   FLOAT64 DEFAULT 6.25;
DECLARE price_per_slot  FLOAT64 DEFAULT 0.06;

-- Leave empty [] to scan only the project this query runs in.
DECLARE target_projects ARRAY<STRING> DEFAULT [];

-- "Workloads to move" list. Stats are always computed over window_days -- one
-- day is too thin a sample to classify a lane on -- but the list is filtered to
-- things that actually ran recently, so it reads as a work queue.
--   recent_days = 1  -> ran yesterday or today
--   recent_days = 7  -> ran this week
DECLARE recent_days       INT64 DEFAULT 1;
-- Only sources whose billing lane you can actually re-route via config.
DECLARE actionable_sources ARRAY<STRING> DEFAULT ['dbt', 'scheduled_query'];

-- ------------------------------------------------------------- internal ----
DECLARE break_even      FLOAT64 DEFAULT price_per_tib / price_per_slot;
DECLARE projects        ARRAY<STRING>;
DECLARE ok_projects     ARRAY<STRING> DEFAULT [];
DECLARE failed_projects ARRAY<STRING> DEFAULT [];
DECLARE p               STRING;
DECLARE i               INT64 DEFAULT 0;
DECLARE storage_errors  INT64 DEFAULT 0;
DECLARE demand_days     INT64 DEFAULT 0;
DECLARE billing_errors  INT64 DEFAULT 0;

SET projects = IF(ARRAY_LENGTH(target_projects) = 0,
                  [@@project_id], target_projects);
SET demand_days = LEAST(window_days, 30);

-- ---------------------------------------------------------------- tables ---
CREATE TEMP TABLE _jobs (
  project_id STRING, principal_hash STRING, is_on_demand BOOL,
  cache_hits INT64, jobs INT64, tib_billed FLOAT64, slot_hours FLOAT64,
  merge_jobs INT64, over_1h_jobs INT64,
  text_jobs INT64, select_star_jobs INT64,
  cross_join_jobs INT64, unbounded_sort_jobs INT64
);

CREATE TEMP TABLE _demand_raw (minute TIMESTAMP, slots FLOAT64);

-- One row per (project, source, workload, billing lane). "Workload" means a dbt
-- node, a scheduled query's destination table, or a Looker Explore -- the unit a
-- person can actually act on, as opposed to an individual job id.
CREATE TEMP TABLE _workloads (
  project_id STRING, source_type STRING, workload_id STRING, is_on_demand BOOL,
  jobs INT64, tib_billed FLOAT64, slot_hours FLOAT64, avg_runtime_s FLOAT64,
  destination_table STRING, last_run TIMESTAMP, runs_recent INT64
);

CREATE TEMP TABLE _storage (
  project_id STRING, dataset STRING, table_count INT64,
  active_logical_gib FLOAT64, long_term_logical_gib FLOAT64,
  active_physical_gib FLOAT64, long_term_physical_gib FLOAT64,
  time_travel_gib FLOAT64, fail_safe_gib FLOAT64,
  compression_x FLOAT64, churn_ratio FLOAT64
);

CREATE TEMP TABLE _billing_model (project_id STRING, dataset STRING, billing_model STRING);
-- projects whose SCHEMATA_OPTIONS we successfully read
CREATE TEMP TABLE _billing_readable (project_id STRING);
CREATE TEMP TABLE _reservations (
  reservation_name STRING, edition STRING, slot_capacity INT64,
  autoscale_max INT64, max_slots INT64, scaling_mode STRING, ignore_idle_slots BOOL
);

-- ============================================================================
--  Per-project collection. Each project is independent: a failure is recorded
--  and skipped, never fatal.
-- ============================================================================
LOOP
  SET i = i + 1;
  IF i > ARRAY_LENGTH(projects) THEN LEAVE; END IF;
  SET p = projects[ORDINAL(i)];

  BEGIN
    -- 1. jobs, including query-text flags (JOBS_BY_PROJECT exposes `query`,
    --    unlike the organization-scoped view)
    EXECUTE IMMEDIATE FORMAT("""
      INSERT INTO _jobs
      SELECT
        project_id,
        TO_HEX(SHA256(user_email)),
        reservation_id IS NULL,
        COUNTIF(cache_hit),
        COUNT(*),
        SUM(total_bytes_billed) / POW(1024,4),
        SUM(total_slot_ms) / 3600000,
        COUNTIF(statement_type = 'MERGE'),
        COUNTIF(TIMESTAMP_DIFF(end_time, start_time, MINUTE) > 60),
        COUNTIF(query IS NOT NULL),
        COUNTIF(REGEXP_CONTAINS(query, r'(?i)SELECT[[:space:]]+[*]')),
        COUNTIF(REGEXP_CONTAINS(query, r'(?i)CROSS[[:space:]]+JOIN')),
        COUNTIF(REGEXP_CONTAINS(query, r'(?i)ORDER[[:space:]]+BY')
                AND NOT REGEXP_CONTAINS(query, r'(?i)[[:space:]]LIMIT[[:space:]]'))
      FROM `%s`.`%s`.INFORMATION_SCHEMA.JOBS_BY_PROJECT
      WHERE creation_time >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL %d DAY)
        AND job_type = 'QUERY'
        AND state = 'DONE'
        AND error_result IS NULL
        AND (statement_type IS NULL OR statement_type != 'SCRIPT')
      GROUP BY 1, 2, 3
    """, p, bq_region, window_days);

    -- 1b. workload attribution. dbt stamps a JSON comment carrying node_id;
    --     scheduled queries carry a job_id prefix; Looker stamps a context
    --     comment. Query text is matched here and never emitted.
    EXECUTE IMMEDIATE FORMAT("""
      INSERT INTO _workloads
      SELECT
        project_id,
        CASE
          WHEN REGEXP_CONTAINS(query, r'"app":[[:space:]]*"dbt"')      THEN 'dbt'
          WHEN STARTS_WITH(job_id, 'scheduled_query_')                 THEN 'scheduled_query'
          WHEN REGEXP_CONTAINS(query, r'(?i)Looker Query Context')      THEN 'looker'
          WHEN REGEXP_CONTAINS(query, r'(?i)dataform')                  THEN 'dataform'
          ELSE 'other'
        END,
        COALESCE(
          REGEXP_EXTRACT(query, r'"node_id":[[:space:]]*"([^"]+)"'),
          CONCAT(destination_table.dataset_id, '.', destination_table.table_id),
          'unattributed'
        ),
        reservation_id IS NULL,
        COUNT(*),
        SUM(total_bytes_billed) / POW(1024,4),
        SUM(total_slot_ms) / 3600000,
        AVG(TIMESTAMP_DIFF(end_time, start_time, SECOND)),
        -- the real output table: skip dbt's __dbt_tmp staging tables and the
        -- anonymous _xxx datasets BigQuery uses for cached results
        MAX(IF(destination_table.table_id IS NOT NULL
               AND NOT ENDS_WITH(destination_table.table_id, '__dbt_tmp')
               AND NOT STARTS_WITH(destination_table.dataset_id, '_'),
               CONCAT(destination_table.project_id, '.',
                      destination_table.dataset_id, '.',
                      destination_table.table_id),
               NULL)),
        MAX(creation_time),
        COUNTIF(DATE(creation_time) >= DATE_SUB(CURRENT_DATE(), INTERVAL %d DAY))
      FROM `%s`.`%s`.INFORMATION_SCHEMA.JOBS_BY_PROJECT
      WHERE creation_time >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL %d DAY)
        AND job_type = 'QUERY'
        AND state = 'DONE'
        AND error_result IS NULL
        AND (statement_type IS NULL OR statement_type != 'SCRIPT')
      GROUP BY 1, 2, 3, 4
    """, recent_days, p, bq_region, window_days);

    -- 2. per-minute slot demand
    EXECUTE IMMEDIATE FORMAT("""
      INSERT INTO _demand_raw
      SELECT TIMESTAMP_TRUNC(period_start, MINUTE),
             SUM(period_slot_ms) / 60000
      FROM `%s`.`%s`.INFORMATION_SCHEMA.JOBS_TIMELINE_BY_PROJECT
      WHERE period_start >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL %d DAY)
        AND job_type = 'QUERY'
        -- a multi-statement SCRIPT emits a parent row AND child rows; counting
        -- both double-bills the slot-ms
        AND (statement_type IS NULL OR statement_type != 'SCRIPT')
      GROUP BY 1
    """, p, bq_region, demand_days);

    SET ok_projects = ARRAY_CONCAT(ok_projects, [p]);
  EXCEPTION WHEN ERROR THEN
    SET failed_projects = ARRAY_CONCAT(failed_projects, [p]);
  END;

  -- 3. storage (separate block: metadataViewer may be granted where
  --    resourceViewer is not, or the other way round)
  BEGIN
    EXECUTE IMMEDIATE FORMAT("""
      INSERT INTO _storage
      SELECT
        project_id, table_schema, COUNT(*),
        SUM(active_logical_bytes)       / POW(1024,3),
        SUM(long_term_logical_bytes)    / POW(1024,3),
        SUM(active_physical_bytes)      / POW(1024,3),
        SUM(long_term_physical_bytes)   / POW(1024,3),
        SUM(time_travel_physical_bytes) / POW(1024,3),
        SUM(fail_safe_physical_bytes)   / POW(1024,3),
        SAFE_DIVIDE(SUM(total_logical_bytes), SUM(total_physical_bytes)),
        SAFE_DIVIDE(SUM(time_travel_physical_bytes), SUM(active_physical_bytes))
      FROM `%s`.`%s`.INFORMATION_SCHEMA.TABLE_STORAGE_BY_PROJECT
      WHERE deleted = FALSE AND table_type = 'BASE TABLE'
      GROUP BY project_id, table_schema
      HAVING SUM(total_logical_bytes) > POW(1024,3) * 10
    """, p, bq_region);
  EXCEPTION WHEN ERROR THEN SET storage_errors = storage_errors + 1; END;

  -- 4. storage billing model per dataset
  BEGIN
    EXECUTE IMMEDIATE FORMAT("""
      INSERT INTO _billing_model
      SELECT '%s', schema_name, CAST(option_value AS STRING)
      FROM `%s`.`%s`.INFORMATION_SCHEMA.SCHEMATA_OPTIONS
      WHERE option_name = 'storage_billing_model'
    """, p, p, bq_region);
    -- reached only if the INSERT succeeded
    EXECUTE IMMEDIATE FORMAT(
      "INSERT INTO _billing_readable VALUES ('%s')", p);
  EXCEPTION WHEN ERROR THEN SET billing_errors = billing_errors + 1; END;

  -- 5. reservations (only populated if p is a reservation admin project)
  --    `autoscale` is a STRUCT: the ceiling is autoscale.max_slots. Reservations
  --    using scaling_mode put the real cap in the top-level max_slots column and
  --    leave autoscale.max_slots at 0, so both are collected. Older schemas lack
  --    max_slots/scaling_mode entirely, hence the fallback attempt.
  BEGIN
    EXECUTE IMMEDIATE FORMAT("""
      INSERT INTO _reservations
      SELECT reservation_name, edition, slot_capacity,
             autoscale.max_slots, max_slots, scaling_mode, ignore_idle_slots
      FROM `%s`.`%s`.INFORMATION_SCHEMA.RESERVATIONS
    """, p, bq_region);
  EXCEPTION WHEN ERROR THEN
    BEGIN
      EXECUTE IMMEDIATE FORMAT("""
        INSERT INTO _reservations
        SELECT reservation_name, edition, slot_capacity,
               autoscale.max_slots, CAST(NULL AS INT64), CAST(NULL AS STRING),
               ignore_idle_slots
        FROM `%s`.`%s`.INFORMATION_SCHEMA.RESERVATIONS
      """, p, bq_region);
    EXCEPTION WHEN ERROR THEN SET i = i; END;   -- admin project only; normal to fail
  END;

END LOOP;

-- ============================================================================
--  RESULT  ·  one row, one JSON column
-- ============================================================================
SELECT TO_JSON_STRING(STRUCT(
  '2.0'                                                AS scan_version,
  'PROJECT'                                            AS scope,
  CURRENT_TIMESTAMP()                                  AS generated_at,
  bq_region                                            AS region,
  window_days                                          AS window_days,
  ok_projects                                          AS projects_scanned,
  recent_days                                          AS recent_days,
  actionable_sources                                   AS actionable_sources,
  failed_projects                                      AS projects_skipped,
  STRUCT(storage_errors AS storage, billing_errors AS billing_model)
                                                       AS partial_read_errors,
  STRUCT(
    price_per_tib                                      AS on_demand_per_tib,
    price_per_slot                                     AS capacity_per_slot_hour,
    ROUND(break_even, 1)                               AS break_even_slot_hrs_per_tib
  )                                                    AS assumptions,

  (SELECT AS STRUCT
     SUM(jobs)                                                AS jobs,
     ROUND(SUM(tib_billed), 2)                                AS tib_billed,
     ROUND(SUM(slot_hours), 1)                                AS slot_hours,
     ROUND(SUM(IF(is_on_demand, tib_billed, 0)), 2)           AS on_demand_tib,
     ROUND(SUM(IF(is_on_demand, tib_billed, 0)) * price_per_tib, 0)
                                                              AS on_demand_cost_window,
     ROUND(SUM(IF(is_on_demand, slot_hours, 0)), 1)           AS on_demand_slot_hours,
     ROUND(SAFE_DIVIDE(SUM(IF(is_on_demand, slot_hours, 0)),
                       SUM(IF(is_on_demand, tib_billed, 0))), 1)
                                                              AS on_demand_slot_hrs_per_tib,
     ROUND(SUM(IF(NOT is_on_demand, slot_hours, 0)), 1)       AS reservation_slot_hours,
     ROUND(SAFE_DIVIDE(SUM(cache_hits), SUM(jobs)) * 100, 1)  AS cache_hit_pct,
     ROUND(SAFE_DIVIDE(SUM(slot_hours), SUM(tib_billed)), 1)  AS overall_slot_hrs_per_tib
   FROM _jobs)                                                AS compute,

  -- Cross-check. These two measure the same thing by different routes; if they
  -- disagree by more than a few percent the timeline is double-counting and the
  -- demand chart cannot be trusted.
  (SELECT AS STRUCT
     ROUND((SELECT SUM(slots) FROM _demand_raw) / 60, 1)      AS timeline_slot_hours,
     ROUND((SELECT SUM(slot_hours) FROM _jobs), 1)            AS jobs_slot_hours,
     ROUND(SAFE_DIVIDE((SELECT SUM(slots) FROM _demand_raw) / 60,
                       (SELECT SUM(slot_hours) FROM _jobs)), 3) AS ratio
  )                                                           AS reconciliation,

  (SELECT AS STRUCT
     SUM(merge_jobs)          AS merge_jobs,
     SUM(over_1h_jobs)        AS over_1h_jobs,
     SUM(text_jobs)           AS text_scanned_jobs,
     SUM(select_star_jobs)    AS select_star_jobs,
     SUM(cross_join_jobs)     AS cross_join_jobs,
     SUM(unbounded_sort_jobs) AS unbounded_sort_jobs
   FROM _jobs)                                                AS antipatterns,

  ARRAY(
    SELECT AS STRUCT
      project_id, principal_hash,
      SUM(jobs)                                             AS jobs,
      ROUND(SUM(tib_billed), 2)                             AS tib_billed,
      ROUND(SUM(slot_hours), 1)                             AS slot_hours,
      ROUND(SAFE_DIVIDE(SUM(slot_hours), SUM(tib_billed)), 1) AS slot_hrs_per_tib,
      -- both lanes priced over the scan window, so the comparison is visible
      -- rather than implied by the ratio
      ROUND(SUM(tib_billed) * price_per_tib, 2)             AS cost_if_on_demand,
      ROUND(SUM(slot_hours) * price_per_slot * 1.2, 2)      AS cost_if_capacity,
      ROUND(SUM(IF(is_on_demand,
                   tib_billed * price_per_tib,
                   slot_hours * price_per_slot * 1.2)), 2)  AS cost_current,
      ROUND(GREATEST(
        SUM(IF(is_on_demand, tib_billed * price_per_tib,
                             slot_hours * price_per_slot * 1.2))
        - LEAST(SUM(tib_billed) * price_per_tib,
                SUM(slot_hours) * price_per_slot * 1.2), 0), 2)
                                                            AS saving_if_optimal,
      IF(SAFE_DIVIDE(SUM(slot_hours), SUM(tib_billed)) < break_even,
         'capacity_cheaper', 'on_demand_cheaper')           AS cheaper_lane
    FROM _jobs
    GROUP BY project_id, principal_hash
    ORDER BY slot_hours DESC   -- the alias, already ROUND(SUM(slot_hours))
    LIMIT 25
  )                                                            AS top_consumers,

  ARRAY(
    SELECT AS STRUCT
      EXTRACT(HOUR FROM minute)                               AS hour_utc,
      -- True hourly average: total slot-minutes divided by EVERY minute in the
      -- window, including idle ones. JOBS_TIMELINE emits no row for an idle
      -- minute, so AVG() over observed rows is "average while busy" and runs
      -- high -- sizing a baseline off it overprovisions.
      CAST(ROUND(SUM(slots) / (demand_days * 60)) AS INT64)   AS avg_slots,
      -- Percentiles are over ACTIVE minutes only, which is what you want for
      -- ceiling sizing: the ceiling has to cover load when load exists.
      CAST(ROUND(AVG(slots)) AS INT64)                        AS avg_slots_active,
      COUNT(*)                                                AS active_minutes,
      demand_days * 60                                        AS total_minutes,
      CAST(ROUND(APPROX_QUANTILES(slots, 100)[OFFSET(50)]) AS INT64) AS p50_slots,
      CAST(ROUND(APPROX_QUANTILES(slots, 100)[OFFSET(95)]) AS INT64) AS p95_slots,
      CAST(ROUND(MAX(slots)) AS INT64)                        AS peak_slots
    FROM (SELECT minute, SUM(slots) AS slots FROM _demand_raw GROUP BY minute)
    GROUP BY hour_utc
    ORDER BY hour_utc
  )                                                            AS demand_by_hour,

  (SELECT AS STRUCT
     FORMAT_TIMESTAMP('%F %H:%M', minute)                     AS at_utc,
     CAST(ROUND(slots) AS INT64)                              AS slots
   FROM (SELECT minute, SUM(slots) AS slots FROM _demand_raw GROUP BY minute)
   ORDER BY slots DESC LIMIT 1)                               AS busiest_minute,

  ARRAY(
    SELECT AS STRUCT
      project_id, dataset, table_count, compression_x, churn_ratio,
      billing_model, logical_cost_month, physical_cost_month, recommended_model,
      billing_model = recommended_model                        AS already_correct,
      -- positive = saving available; negative = currently overpaying
      ROUND(IF(billing_model = 'PHYSICAL', physical_cost_month, logical_cost_month)
          - IF(recommended_model = 'PHYSICAL', physical_cost_month, logical_cost_month),
            0)                                                 AS monthly_delta,
      CASE
        WHEN billing_model = 'UNKNOWN'            THEN 'unknown_billing_model'
        WHEN billing_model = recommended_model    THEN 'already_optimal'
        WHEN recommended_model = 'PHYSICAL'       THEN 'switch_to_physical'
        ELSE                                           'switch_to_logical'
      END                                                      AS verdict,
      IF(churn_ratio > 0.5, TRUE, FALSE)                       AS high_churn
    FROM (
      SELECT
        s.project_id, s.dataset, s.table_count,
        ROUND(s.compression_x, 1)                  AS compression_x,
        ROUND(s.churn_ratio, 2)                    AS churn_ratio,
        -- absent from SCHEMATA_OPTIONS means the dataset is on the LOGICAL
        -- default, provided we could read that project's options at all
        COALESCE(b.billing_model,
                 IF(r.project_id IS NOT NULL, 'LOGICAL', 'UNKNOWN'))
                                                   AS billing_model,
        ROUND(s.active_logical_gib * 0.02
            + s.long_term_logical_gib * 0.01, 0)   AS logical_cost_month,
        ROUND((s.active_physical_gib + s.time_travel_gib + s.fail_safe_gib) * 0.04
            + s.long_term_physical_gib * 0.02, 0)  AS physical_cost_month,
        -- decided on measured cost, with a churn guard: heavy UPDATE/MERGE
        -- traffic makes physical risky even when today's numbers look good
        CASE
          WHEN s.churn_ratio > 0.5 THEN 'LOGICAL'
          WHEN ((s.active_physical_gib + s.time_travel_gib + s.fail_safe_gib) * 0.04
                + s.long_term_physical_gib * 0.02)
               < (s.active_logical_gib * 0.02 + s.long_term_logical_gib * 0.01) * 0.9
            THEN 'PHYSICAL'
          ELSE 'LOGICAL'
        END                                        AS recommended_model
      FROM _storage s
      LEFT JOIN _billing_model b
        ON b.project_id = s.project_id AND b.dataset = s.dataset
      LEFT JOIN (SELECT DISTINCT project_id FROM _billing_readable) r
        ON r.project_id = s.project_id
    )
    ORDER BY ABS(IF(billing_model = 'PHYSICAL', physical_cost_month, logical_cost_month)
                - IF(recommended_model = 'PHYSICAL', physical_cost_month, logical_cost_month)) DESC
    LIMIT 40
  )                                                            AS storage,

  ARRAY(
    SELECT AS STRUCT
      project_id, source_type, workload_id,
      destination_table,
      last_run, runs_recent,
      IF(is_on_demand, 'on_demand', 'reservation')           AS current_lane,
      jobs, avg_runtime_s,
      ROUND(tib_billed, 3)                                   AS tib_billed,
      ROUND(slot_hours, 2)                                   AS slot_hours,
      ROUND(SAFE_DIVIDE(slot_hours, tib_billed), 1)          AS slot_hrs_per_tib,
      ROUND(tib_billed * price_per_tib, 2)                   AS cost_if_on_demand,
      ROUND(slot_hours * price_per_slot * 1.2, 2)            AS cost_if_capacity,
      IF(tib_billed * price_per_tib <= slot_hours * price_per_slot * 1.2,
         'on_demand', 'capacity')                            AS recommended_lane,
      IF(is_on_demand, 'on_demand', 'capacity') =
        IF(tib_billed * price_per_tib <= slot_hours * price_per_slot * 1.2,
           'on_demand', 'capacity')                          AS already_correct,
      ROUND(
        GREATEST(
          IF(is_on_demand, tib_billed * price_per_tib, slot_hours * price_per_slot * 1.2)
          - LEAST(tib_billed * price_per_tib, slot_hours * price_per_slot * 1.2),
        0) * (365.0 / window_days), 2)                       AS annual_saving_if_moved
    FROM _workloads
    WHERE source_type IN UNNEST(actionable_sources)
      AND runs_recent > 0                    -- ran within recent_days
      AND workload_id != 'unattributed'
    ORDER BY slot_hours DESC
    LIMIT 250
  )                                                            AS workloads,

  ARRAY(
    SELECT AS STRUCT
      reservation_name, edition, slot_capacity, scaling_mode, ignore_idle_slots,
      autoscale_max, max_slots,
      COALESCE(NULLIF(max_slots, 0), NULLIF(autoscale_max, 0)) AS effective_ceiling
    FROM _reservations
  )                                                            AS reservations
)) AS costscan_result;
