#!/bin/bash
# verify.sh — TechStream Self-Healing lab (Step 7)
# End-to-end smoke test for every layer of the self-healing stack.
# Run from the EC2 instance itself OR from any machine with AWS CLI access.
#
# Usage:
#   ./verify.sh                        # run all checks
#   ./verify.sh --local-only           # skip AWS API checks (useful on the instance)
#   ./verify.sh --aws-only             # skip local systemd/curl checks
#
# Exit codes:  0 = all checks passed   1 = one or more checks failed

set -euo pipefail

REGION="us-east-1"
NAMESPACE="TechStream/WebServer"
ALARM_NAME="TechStream-HighErrorRate"
LAMBDA_NAME="TechStream-Remediate"
ASG_NAME="TechStream-ASG"
APP_URL="${APP_URL:-http://localhost:5000}"
CFN_STACK_NAME="TechStream-SelfHealing"

LOCAL_ONLY=false
AWS_ONLY=false
[[ "${1:-}" == "--local-only" ]] && LOCAL_ONLY=true
[[ "${1:-}" == "--aws-only"  ]] && AWS_ONLY=true

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
PASS=0; FAIL=0; WARN=0

ts()   { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log()  { echo "[$(ts)] $*"; }

pass() { echo "  [PASS] $*"; (( PASS++ )) || true; }
fail() { echo "  [FAIL] $*"; (( FAIL++ )) || true; }
warn() { echo "  [WARN] $*"; (( WARN++ )) || true; }

section() {
    echo ""
    echo "========================================================"
    echo "  $*"
    echo "========================================================"
}

summary() {
    echo ""
    echo "========================================================"
    echo "  RESULTS:  PASS=${PASS}  FAIL=${FAIL}  WARN=${WARN}"
    echo "========================================================"
    [[ $FAIL -eq 0 ]] && { echo "  All critical checks passed."; exit 0; } \
                       || { echo "  One or more checks FAILED — review output above."; exit 1; }
}

# ---------------------------------------------------------------------------
# Check 1 — Flask app process and /health endpoint
# ---------------------------------------------------------------------------
check_flask() {
    section "1. Flask application"

    if systemctl is-active --quiet techstream-app 2>/dev/null; then
        pass "systemd service techstream-app is active"
    else
        fail "systemd service techstream-app is NOT active"
        log "  Run: sudo systemctl status techstream-app"
    fi

    if systemctl is-enabled --quiet techstream-app 2>/dev/null; then
        pass "techstream-app is enabled (survives reboot)"
    else
        warn "techstream-app is NOT enabled — will not start on reboot"
    fi

    # /health must return HTTP 200
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "${APP_URL}/health" 2>/dev/null || echo "000")
    if [[ "$http_code" == "200" ]]; then
        pass "/health returned HTTP ${http_code}"
    else
        fail "/health returned HTTP ${http_code} (expected 200) — app may be down or wrong port"
    fi

    # /metrics must be reachable
    local metrics_code
    metrics_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "${APP_URL}/metrics" 2>/dev/null || echo "000")
    if [[ "$metrics_code" == "200" ]]; then
        pass "/metrics returned HTTP ${metrics_code}"
    else
        warn "/metrics returned HTTP ${metrics_code} — CloudWatch scraping may fail"
    fi

    # Log file must exist and be non-empty
    if [[ -s /var/log/app.log ]]; then
        local lines
        lines=$(wc -l < /var/log/app.log)
        pass "/var/log/app.log exists and has ${lines} lines"
    else
        warn "/var/log/app.log is empty or missing — JSON logging may not be configured"
    fi
}

# ---------------------------------------------------------------------------
# Check 2 — CloudWatch agent
# ---------------------------------------------------------------------------
check_cw_agent() {
    section "2. CloudWatch agent"

    if systemctl is-active --quiet amazon-cloudwatch-agent 2>/dev/null; then
        pass "amazon-cloudwatch-agent service is active"
    else
        fail "amazon-cloudwatch-agent is NOT active"
        log "  Run: sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -s -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json"
    fi

    local cw_cfg="/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json"
    if [[ -f "$cw_cfg" ]]; then
        pass "Agent config file exists: ${cw_cfg}"
    else
        fail "Agent config file missing: ${cw_cfg}"
    fi

    # Verify agent log for recent errors
    local agent_log="/opt/aws/amazon-cloudwatch-agent/logs/amazon-cloudwatch-agent.log"
    if [[ -f "$agent_log" ]]; then
        local recent_errors
        recent_errors=$(grep -c "ERROR" "$agent_log" 2>/dev/null || echo 0)
        if [[ "$recent_errors" -eq 0 ]]; then
            pass "No ERRORs found in agent log"
        else
            warn "${recent_errors} ERROR line(s) found in ${agent_log} — check agent config"
        fi
    else
        warn "Agent log not found — agent may not have written anything yet"
    fi
}

# ---------------------------------------------------------------------------
# Check 3 — Custom metrics visible in CloudWatch
# ---------------------------------------------------------------------------
check_metrics() {
    section "3. CloudWatch custom metrics (namespace: ${NAMESPACE})"

    local expected_metrics=(
        "techstream_requests_total"
        "techstream_errors_total"
        "techstream_error_rate_percent"
        "cpu_usage_idle"
        "mem_used_percent"
        "disk_used_percent"
    )

    # Fetch all metrics in the namespace once
    local all_metrics
    all_metrics=$(aws cloudwatch list-metrics \
        --namespace "$NAMESPACE" \
        --region "$REGION" \
        --output json 2>/dev/null | jq -r '.Metrics[].MetricName' || echo "")

    if [[ -z "$all_metrics" ]]; then
        fail "No metrics found in namespace ${NAMESPACE} — agent may not have pushed yet (wait ~2 min)"
        return
    fi

    for metric in "${expected_metrics[@]}"; do
        if echo "$all_metrics" | grep -qx "$metric"; then
            pass "Metric present: ${metric}"
        else
            warn "Metric NOT found: ${metric} — may arrive within the next collection interval"
        fi
    done

    # Print latest value of error_rate so the operator can sanity-check
    local latest_err_rate
    latest_err_rate=$(aws cloudwatch get-metric-statistics \
        --namespace "$NAMESPACE" \
        --metric-name "techstream_error_rate_percent" \
        --dimensions Name=AutoScalingGroupName,Value="$ASG_NAME" \
        --start-time "$(date -u -d '5 minutes ago' +%FT%TZ 2>/dev/null || date -u -v-5M +%FT%TZ)" \
        --end-time "$(date -u +%FT%TZ)" \
        --period 60 \
        --statistics Average \
        --region "$REGION" \
        --output json 2>/dev/null \
        | jq -r '.Datapoints | sort_by(.Timestamp) | last | .Average // "no data"' 2>/dev/null \
        || echo "unavailable")
    log "  Latest error_rate_percent (last 5 min avg): ${latest_err_rate}"
}

# ---------------------------------------------------------------------------
# Check 4 — CloudWatch alarm state
# ---------------------------------------------------------------------------
check_alarm() {
    section "4. CloudWatch alarm: ${ALARM_NAME}"

    local alarm_json
    alarm_json=$(aws cloudwatch describe-alarms \
        --alarm-names "$ALARM_NAME" \
        --region "$REGION" \
        --output json 2>/dev/null || echo '{"MetricAlarms":[]}')

    local state
    state=$(echo "$alarm_json" | jq -r '.MetricAlarms[0].StateValue // "NOT_FOUND"')

    case "$state" in
        OK)
            pass "Alarm '${ALARM_NAME}' exists and is in state: OK"
            ;;
        ALARM)
            warn "Alarm '${ALARM_NAME}' is in state: ALARM — remediation should be in progress"
            ;;
        INSUFFICIENT_DATA)
            warn "Alarm '${ALARM_NAME}' is in state: INSUFFICIENT_DATA — metrics not arriving yet"
            ;;
        NOT_FOUND)
            fail "Alarm '${ALARM_NAME}' does not exist — run: terraform apply"
            ;;
        *)
            fail "Alarm '${ALARM_NAME}' is in unexpected state: ${state}"
            ;;
    esac

    # Check alarm actions are configured
    local actions
    actions=$(echo "$alarm_json" | jq -r '.MetricAlarms[0].AlarmActions | length' 2>/dev/null || echo 0)
    if [[ "$actions" -gt 0 ]]; then
        pass "Alarm has ${actions} action(s) configured"
    else
        warn "Alarm has no actions — SNS/EventBridge not wired"
    fi
}

# ---------------------------------------------------------------------------
# Check 5 — Lambda function + last invocation
# ---------------------------------------------------------------------------
check_lambda() {
    section "5. Lambda function: ${LAMBDA_NAME}"

    # Check function exists
    local fn_json
    fn_json=$(aws lambda get-function \
        --function-name "$LAMBDA_NAME" \
        --region "$REGION" \
        --output json 2>/dev/null || echo "null")

    if [[ "$fn_json" == "null" ]]; then
        fail "Lambda function '${LAMBDA_NAME}' does not exist"
        return
    fi

    local runtime state
    runtime=$(echo "$fn_json" | jq -r '.Configuration.Runtime')
    state=$(echo "$fn_json" | jq -r '.Configuration.State')
    pass "Lambda '${LAMBDA_NAME}' exists (runtime=${runtime}, state=${state})"

    [[ "$runtime" == "python3.12" ]] && pass "Runtime is python3.12" \
        || warn "Runtime is ${runtime} — expected python3.12"

    # Check last invocation via CloudWatch Logs metric filter
    local log_group="/aws/lambda/${LAMBDA_NAME}"
    local last_invocation
    last_invocation=$(aws logs describe-log-streams \
        --log-group-name "$log_group" \
        --order-by LastEventTime \
        --descending \
        --max-items 1 \
        --region "$REGION" \
        --output json 2>/dev/null \
        | jq -r '.logStreams[0].lastEventTimestamp // 0' || echo 0)

    if [[ "$last_invocation" -gt 0 ]]; then
        local last_ts
        last_ts=$(date -u -d "@$(( last_invocation / 1000 ))" +%FT%TZ 2>/dev/null \
               || date -u -r  $(( last_invocation / 1000 )) +%FT%TZ 2>/dev/null \
               || echo "unknown")
        pass "Lambda last logged activity: ${last_ts}"
    else
        warn "No log events found in ${log_group} — Lambda has never been invoked or log group missing"
    fi

    # Check last invocation succeeded by searching for the "complete" log line
    local last_status
    last_status=$(aws logs filter-log-events \
        --log-group-name "$log_group" \
        --filter-pattern '{ $.action = "complete" }' \
        --start-time "$(( ($(date +%s) - 3600) * 1000 ))" \
        --region "$REGION" \
        --output json 2>/dev/null \
        | jq -r '[.events[] | .message | fromjson | .result.status] | last // "never"' 2>/dev/null \
        || echo "unavailable")
    log "  Last remediation result (past 1 h): ${last_status}"

    if [[ "$last_status" == "remediated" ]]; then
        pass "Last Lambda invocation result: remediated"
    elif [[ "$last_status" == "failed" ]]; then
        warn "Last Lambda invocation result: failed — check CloudWatch Logs"
    else
        warn "No recent Lambda invocation found (status=${last_status})"
    fi
}

# ---------------------------------------------------------------------------
# Check 6 — DevOps Guru enabled on resource collection
# ---------------------------------------------------------------------------
check_devops_guru() {
    section "6. DevOps Guru resource collection"

    local collection
    collection=$(aws devops-guru get-resource-collection \
        --resource-collection-type "AWS_CLOUD_FORMATION" \
        --region "$REGION" \
        --output json 2>/dev/null || echo '{}')

    local stack_count
    stack_count=$(echo "$collection" \
        | jq -r '.ResourceCollection.CloudFormation.StackNames | length' 2>/dev/null || echo 0)

    if [[ "$stack_count" -gt 0 ]]; then
        local stacks
        stacks=$(echo "$collection" | jq -r '.ResourceCollection.CloudFormation.StackNames[]')
        pass "DevOps Guru is monitoring ${stack_count} CloudFormation stack(s): ${stacks}"
    else
        fail "DevOps Guru has no stacks in its resource collection — run: ./devops-guru.sh enable"
    fi

    # Check service integrations
    local ops_center logs_anomaly
    local integrations
    integrations=$(aws devops-guru describe-service-integration \
        --region "$REGION" \
        --output json 2>/dev/null || echo '{}')

    ops_center=$(echo "$integrations" \
        | jq -r '.ServiceIntegration.OpsCenter.OptInStatus // "DISABLED"')
    logs_anomaly=$(echo "$integrations" \
        | jq -r '.ServiceIntegration.LogsAnomalyDetection.OptInStatus // "DISABLED"')

    [[ "$ops_center"   == "ENABLED" ]] \
        && pass "OpsCenter integration: ENABLED" \
        || warn "OpsCenter integration: ${ops_center}"

    [[ "$logs_anomaly" == "ENABLED" ]] \
        && pass "LogsAnomalyDetection integration: ENABLED" \
        || warn "LogsAnomalyDetection integration: ${logs_anomaly}"

    # Report any open reactive insights
    local insight_count
    insight_count=$(aws devops-guru list-insights \
        --status-filter '{"Any": {"Type": "REACTIVE"}}' \
        --region "$REGION" \
        --output json 2>/dev/null \
        | jq '.ReactiveInsights | length' 2>/dev/null || echo "unknown")
    log "  Open reactive insights: ${insight_count}"
}

# ---------------------------------------------------------------------------
# Main — run checks based on flags
# ---------------------------------------------------------------------------
log "=== TechStream Self-Healing — Verification Script ==="
log "    APP_URL=${APP_URL}   REGION=${REGION}"

if ! $AWS_ONLY; then
    check_flask
    check_cw_agent
fi

if ! $LOCAL_ONLY; then
    check_metrics
    check_alarm
    check_lambda
    check_devops_guru
fi

summary
