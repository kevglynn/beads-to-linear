# Monitoring Setup Guide

**Last updated:** 2026-05-02
**Audience:** Ops engineers, team leads setting up sync monitoring
**Cross-reference:** [Runbook §10 — Monitoring and Alerting](runbooks/linear-sync.md#10-monitoring-and-alerting)

---

## Table of Contents

1. [Quick Start](#1-quick-start)
2. [Slack Notifications](#2-slack-notifications)
3. [GitHub Actions Native Alerting](#3-github-actions-native-alerting)
4. [Datadog Integration](#4-datadog-integration-optional)
5. [Grafana Integration](#5-grafana-integration-optional)
6. [Dashboard Panels](#6-dashboard-panels)
7. [Alert Routing](#7-alert-routing)
8. [Health Check Script Reference](#8-health-check-script-reference)
9. [Metrics Reference](#9-metrics-reference)

---

## 1. Quick Start

The monitoring system has two layers:

- **Automated:** The `sync-health-monitor.yml` workflow runs every 6 hours, checks system health, and creates GitHub issues tagged `sync-alert` when problems are detected.
- **Manual:** Run `scripts/sync-health-check.sh` locally for an immediate diagnostic.

```bash
# Quick local health check
bash scripts/sync-health-check.sh

# Machine-readable output
bash scripts/sync-health-check.sh --json

# Agent-friendly compact output
bash scripts/sync-health-check.sh --agent
```

No external monitoring platform is required — GitHub Actions + Issues provides baseline alerting out of the box.

---

## 2. Slack Notifications

### Option A: GitHub-native Slack integration (simplest)

1. Install the [GitHub Slack app](https://slack.github.com/) in your Slack workspace
2. In your Slack channel, run:
   ```
   /github subscribe kevglynn/beads-to-linear workflows:{event:"completed" workflow:"Sync Health Monitor"}
   ```
3. Optionally filter to failures only:
   ```
   /github subscribe kevglynn/beads-to-linear workflows:{event:"completed" workflow:"Sync Health Monitor" conclusion:"failure"}
   ```

This sends a Slack notification whenever the health monitor workflow fails (warning or critical).

### Option B: Slack webhook in the workflow

For richer Slack messages with check details, add a step to `sync-health-monitor.yml`:

```yaml
- name: Notify Slack
  if: steps.health.outputs.exit_code != '0'
  uses: slackapi/slack-github-action@v2
  with:
    webhook: ${{ secrets.SLACK_SYNC_WEBHOOK }}
    webhook-type: incoming-webhook
    payload: |
      {
        "text": "Sync Health Alert: ${{ steps.health.outputs.status }}",
        "blocks": [
          {
            "type": "section",
            "text": {
              "type": "mrkdwn",
              "text": "*Sync Health: ${{ steps.health.outputs.status }}*\nRepo: `${{ github.repository }}`\n<${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}|View Run>"
            }
          }
        ]
      }
```

**Setup:**
1. Create a Slack [incoming webhook](https://api.slack.com/messaging/webhooks) for your alerts channel
2. Add the webhook URL as a GitHub Actions secret: `SLACK_SYNC_WEBHOOK`

---

## 3. GitHub Actions Native Alerting

GitHub provides built-in notification options that require no additional setup:

### Email notifications

1. Go to repo **Settings → Notifications → Actions**
2. Enable "Send notifications for failed workflows only"
3. Each repo collaborator receives email on workflow failures

### Watch settings

Individual team members can configure their notification preferences:

1. Click **Watch** on the repository
2. Select **Custom → Workflows** to get notified on workflow events

---

## 4. Datadog Integration (optional)

### Custom check via Datadog Agent

Create a custom Agent check that runs the health check script:

```yaml
# /etc/datadog-agent/conf.d/btl_sync.d/conf.yaml
instances:
  - name: beads_linear_sync
    command: bash /path/to/beads-to-linear/scripts/sync-health-check.sh --json
    shell: /bin/bash
    timeout: 30
```

### Prometheus metrics endpoint

Use `sync-metrics-export.sh` with a Datadog Agent OpenMetrics check:

```yaml
# /etc/datadog-agent/conf.d/openmetrics.d/conf.yaml
instances:
  - prometheus_url: http://localhost:9191/metrics
    namespace: btl
    metrics:
      - btl_sync_success_total
      - btl_sync_failure_total
      - btl_sync_last_success_timestamp
      - btl_sync_issues_pushed
      - btl_sync_issues_pulled
      - btl_sync_conflicts_total
      - btl_sync_api_quota_remaining
      - btl_sync_external_ref_coverage_ratio
```

To serve metrics on an HTTP endpoint, pair the export script with a lightweight server:

```bash
# Simple one-liner with socat (for dev/testing)
while true; do
  socat TCP-LISTEN:9191,reuseaddr,fork \
    SYSTEM:"echo 'HTTP/1.1 200 OK'; echo 'Content-Type: text/plain'; echo ''; bash /path/to/sync-metrics-export.sh"
done
```

For production, use [prom2json](https://github.com/prometheus/prom2json) or a proper exporter container.

---

## 5. Grafana Integration (optional)

### Using Prometheus as a data source

If you already have Prometheus scraping metrics:

1. Add the metrics endpoint to your Prometheus scrape config:
   ```yaml
   scrape_configs:
     - job_name: 'btl-sync'
       scrape_interval: 5m
       static_configs:
         - targets: ['localhost:9191']
   ```

2. Import the dashboard panels described in [§6](#6-dashboard-panels) into Grafana.

### Using GitHub Actions as a data source

The [grafana-github-datasource](https://grafana.com/grafana/plugins/grafana-github-datasource/) plugin can pull workflow run data directly from GitHub:

1. Install the GitHub data source plugin
2. Configure it with a GitHub token that has `actions:read` scope
3. Build panels using workflow run queries

---

## 6. Dashboard Panels

These panels correspond to the metrics and thresholds defined in [Runbook §10](runbooks/linear-sync.md#10-monitoring-and-alerting).

### Panel 1: Sync Health Status

- **Type:** Stat/single value
- **Data:** Latest health check status (healthy/warning/critical)
- **Colors:** Green=healthy, Yellow=warning, Red=critical
- **Metric:** Derived from `btl_sync_last_success_timestamp` vs current time

### Panel 2: Sync Success Rate (7-day trend)

- **Type:** Time series line chart
- **Data:** `btl_sync_success_total / (btl_sync_success_total + btl_sync_failure_total)` over 7d
- **Target:** ≥ 99.5% (shown as horizontal threshold line)
- **Alert:** Fire when rate drops below 99.5% over a 24h window

### Panel 3: Push/Pull Volume

- **Type:** Stacked bar chart
- **Data:** `btl_sync_issues_pushed` and `btl_sync_issues_pulled` per run
- **Timeframe:** Last 7 days
- **Grouping:** Per workflow run

### Panel 4: Conflict Trend

- **Type:** Line chart
- **Data:** `btl_sync_conflicts_total` per run over 30 days
- **Alert:** Fire when conflict count shows sustained upward trend (3+ consecutive increases)

### Panel 5: API Quota Gauge

- **Type:** Gauge
- **Data:** `btl_sync_api_quota_remaining` as percentage of limit (5,000 req/hr)
- **Thresholds:** Green < 80%, Yellow 80–90%, Red > 90%
- **Metric:** `1 - (btl_sync_api_quota_remaining / 5000)` as utilization percentage

### Panel 6: Last Successful Sync

- **Type:** Stat with timestamp
- **Data:** `btl_sync_last_success_timestamp`
- **Alert:** Fire when age exceeds 30 minutes
- **Display:** Shows both timestamp and age (e.g., "2026-05-02T14:00:00Z — 12m ago")

### Panel 7: External Ref Coverage

- **Type:** Gauge (0–100%)
- **Data:** `btl_sync_external_ref_coverage_ratio * 100`
- **Target:** 100%
- **Alert:** Fire when coverage drops below 90%

---

## 7. Alert Routing

### Severity levels

| Severity | Condition | Action | Who |
|----------|-----------|--------|-----|
| **Info** | Health check passes | No action | Dashboard only |
| **Warning** | Single check failure, coverage drift, stale cron | Investigate within 4 hours | On-call engineer |
| **Critical** | 3+ consecutive failures, secrets in config, CI down | Investigate immediately | On-call engineer + team lead |

### Routing table

| Alert | Channel | Escalation |
|-------|---------|------------|
| CI sync failure (single) | Slack `#beads-sync-alerts` | Auto-escalate to critical after 3 consecutive |
| CI sync failure (3+ consecutive) | Slack `#beads-sync-alerts` + GitHub issue `sync-alert` | Page on-call |
| Rate limit breach (429) | Slack `#beads-sync-alerts` | Review push volume |
| Rate limit quota > 90% | Slack `#beads-sync-alerts` | Stagger operations |
| Config drift detected | Slack `#beads-sync-alerts` | Run `validate-config.sh --fix` |
| Secrets in config | GitHub issue `sync-alert` (critical) | Remove immediately |
| Coverage < 90% | Slack `#beads-sync-alerts` | Check CI trigger config |
| JSONL parse error | GitHub issue `sync-alert` (critical) | Resolve merge conflict |

### PagerDuty/Opsgenie (optional)

For teams using PagerDuty or Opsgenie, add an integration to the `sync-health-monitor.yml` workflow:

```yaml
- name: Page on-call (critical only)
  if: steps.health.outputs.exit_code == '2'
  run: |
    curl -X POST "https://events.pagerduty.com/v2/enqueue" \
      -H "Content-Type: application/json" \
      -d '{
        "routing_key": "${{ secrets.PAGERDUTY_ROUTING_KEY }}",
        "event_action": "trigger",
        "payload": {
          "summary": "beads-to-linear sync CRITICAL",
          "severity": "critical",
          "source": "${{ github.repository }}"
        }
      }'
```

---

## 8. Health Check Script Reference

### `scripts/sync-health-check.sh`

| Flag | Description |
|------|-------------|
| `--json` | Output as JSON (machine-consumable) |
| `--agent` | Compact output for agent consumption |
| `--repo OWNER/REPO` | Override GitHub repo detection |
| `--help` | Show help |

**Exit codes:**

| Code | Meaning |
|------|---------|
| 0 | Healthy — all checks passed |
| 1 | Warning — degraded but functional |
| 2 | Critical — immediate attention required |

**Checks performed:**

| Check | What it verifies |
|-------|-----------------|
| `ci_sync_last` | Most recent CI sync run status |
| `ci_sync_age` | Time since last successful sync |
| `ci_consecutive_failures` | Count of consecutive failed runs |
| `coverage_pct` | Percentage of trackable beads with Linear IDs |
| `api_quota` | API quota utilization from last sync log |
| `cron_installed` | Whether the pull cron is installed |
| `cron_age` | Time since last cron activity |
| `cron_errors` | Recent errors in cron log |
| `config_drift` | Config vs org template comparison |
| `blocked_beads` | Beads in blocked state |
| `in_progress_beads` | Potentially orphaned in-progress beads |

---

## 9. Metrics Reference

### `scripts/sync-metrics-export.sh`

Outputs metrics in Prometheus exposition format (text/plain).

| Metric | Type | Description |
|--------|------|-------------|
| `btl_sync_success_total` | counter | Total successful CI sync runs |
| `btl_sync_failure_total` | counter | Total failed CI sync runs |
| `btl_sync_last_success_timestamp` | gauge | Unix timestamp of last successful sync |
| `btl_sync_issues_pushed` | gauge | Issues pushed in the most recent run |
| `btl_sync_issues_pulled` | gauge | Issues pulled in the most recent run |
| `btl_sync_conflicts_total` | gauge | Conflicts in the most recent run |
| `btl_sync_api_quota_remaining` | gauge | API quota remaining after last sync |
| `btl_sync_external_ref_coverage_ratio` | gauge | Fraction of trackable beads with Linear IDs (0.0–1.0) |

| Flag | Description |
|------|-------------|
| `--repo OWNER/REPO` | Override GitHub repo detection |
| `--prefix PREFIX` | Metric name prefix (default: `btl_sync`) |
| `--help` | Show help |
