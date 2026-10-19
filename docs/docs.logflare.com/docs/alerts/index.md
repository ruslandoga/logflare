---
title: Alerts
---

In Logflare, notifications can take one of two forms:

1. A notification of recent logs into a source (hereby referred to as **Legacy Recent Events Alerts**), or
2. a custom query triggered periodically to perform customizable checks (hereby referred to as **Query Alerts**).

When the term **Alerts** is used, it will refer to **Query Alerts**, which is the spiritual successor for the Legacy Recent Events Alerts.

Alerts use Logflare's querying capabilities to run SQL or PromQL expressions for threshold warnings, incident detection, and periodic metrics calculations.

## Query Alerts

### Crafting the Query

Choose **BigQuery SQL** for log queries or **PromQL** for metrics stored in a [VictoriaMetrics backend](/backends/victoria-metrics). BigQuery SQL accepts only `SELECT` statements, similar to Logflare Endpoints.

If there are no rows returned, the Query Alert will not continue with sending out messages to the connected integrations.

### PromQL Alerts

Configure the VictoriaMetrics backend's `query_url`, then select **PromQL** and that **query backend** in the alert form. The query backend is separate from the notification backends. Expressions run as instant queries and can access the metrics permitted by the backend's credentials and tenant URL; Logflare does not add source filters.

Any returned sample triggers the alert, including samples whose value is `0`, `NaN`, or an infinity. Use a filtering comparison to return only the series that should trigger:

```promql
queue_depth{job="api"} > 100
```

For example, `up == 0` returns down targets with value `0`, and those results trigger notifications. Avoid `queue_depth > bool 100`: the `bool` modifier also returns false matches with value `0`, which still trigger. See [Prometheus comparison operators](https://prometheus.io/docs/prometheus/latest/querying/operators/#comparison-binary-operators).

An empty result sends no notification. To detect missing data, express that condition explicitly, for example:

```promql
absent_over_time(heartbeat{job="api"}[10m])
```

Alerts accept instant vectors of float samples and scalar results. Scalars become one result with empty labels, so even a scalar `0` triggers. Range vectors, strings, native histogram samples, malformed responses, and more than 1,000 results fail the evaluation without sending notifications. Narrow the expression or aggregate series to stay within the result limit. Query failures appear in execution history as errors, rather than successful empty results. Upstream warnings are shown with the results.

Each result contains a label map, the sample value as a string, and a Unix timestamp in seconds. Webhook notifications contain these rows:

```json
{
  "result": [
    {
      "labels": { "job": "api", "instance": "api-1" },
      "value": "0",
      "timestamp": 1792404300
    }
  ]
}
```

PromQL alerts use the same scheduled notifications as SQL alerts: each successful nonempty evaluation sends all its results together to each destination. The alert scheduler does not track per-series pending, firing, or resolved state, implement `for`, or deduplicate notifications across evaluations. Destinations may apply their own deduplication. These differ from the full lifecycle of [Prometheus alerting rules](https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/).

### Supported Integrations

The supported integrations are:

1. Slack (via the Logflare v2 app)
2. Webhooks
3. [Incident.io](/backends/incidentio)

### Scheduling

Query Alerts allows for cron-based scheduling, with a minimum interval of 5 minutes. It is advised to keep the queried time range to the bare minimum required so as to reduce query execution time, as queries that cover large time ranges may scan a lot of data and result in a slow query.

PromQL evaluations use the scheduled timestamp minus `evaluation_delay_seconds`, which defaults to 30 and accepts 0–86,400 seconds. For example, a run scheduled for `12:05:00` evaluates at `12:04:30`, even if the worker starts later. This delay allows recently ingested metrics to become queryable; increase it to accommodate your ingestion latency. See [VictoriaMetrics query latency](https://docs.victoriametrics.com/victoriametrics/keyconcepts/#query-latency). Manual previews and triggers use the current time minus the same delay.

### Testing

Use **Test query** in the editor or **Run query** on a saved alert to preview results without sending notifications. The editor tests the current query, language, query backend, and evaluation delay, including unsaved changes. Use **Trigger now** on a saved alert to execute it and dispatch matching results to the connected integrations.

### Example Usage

For example, if we are sending the following events to a source called `my.source`:

```json
{
  "event_message": "Hello from Logflare!",
  "stats": { "counter": 1 },
  "metadata": { "from": "docs" }
}
```

We can then create an alert with the following query with BigQuery SQL:

```sql
select sum(s.counter) as docs_total_hits
from `my.source` t
cross join unnest(t.stats) as s
cross join unnest(t.metadata) as m
where t.timestamp >= '2024-05-05'
    and m.from = 'docs'
```

Queries follow the same structure as needed when [querying a BigQuery Backend](https://docs.logflare.app/backends/bigquery/#querying-in-bigquery), thus we will need to `unnest` the repeated records.

We will also need to include a filter over the `timestamp` field, as BigQuery tables will be [partitioned by Logflare](https://docs.logflare.app/backends/bigquery/#partitioning-and-retention).

If we were to add a webhook integration to this backend, the provided url will receive a `POST` request with the following payload in the body:

```json
{
  "result": [
        { "docs_total_hits": 1 },
        ...
    ]
}
```

### Best Practices

1. For BigQuery SQL, keep the query's `timestamp` range minimal. This helps queries run fast. For rolling metrics, use the [BigQuery timestamp functions](https://cloud.google.com/bigquery/docs/reference/standard-sql/timestamp_functions) to avoid hardcoded dates.

2. Return only the results needed to investigate the alert. SQL queries should include a `LIMIT`; PromQL expressions should filter or aggregate series. BigQuery returns at most 1,000 rows, and PromQL alerts fail if the expression returns more than 1,000 results.
