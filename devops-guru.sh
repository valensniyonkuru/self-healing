#!/bin/bash
# devops-guru.sh — TechStream Self-Healing lab (Step 6)
# Enables Amazon DevOps Guru on the TechStream resource collection,
# triggers chaos to generate anomalies, then exports any resulting insights.
#
# Usage:
#   ./devops-guru.sh enable          # one-time setup
#   ./devops-guru.sh chaos-and-wait  # inject chaos, wait 15 min, then poll
#   ./devops-guru.sh export          # list + describe all insights → JSON files
#   ./devops-guru.sh status          # show current service integration state
#
# Prerequisites:
#   - AWS CLI v2 configured with a profile that has DevOps Guru permissions
#   - jq installed locally
#   - chaos.sh in the same directory (for the chaos-and-wait mode)

set -euo pipefail

REGION="us-east-1"
CFN_STACK_NAME="TechStream-SelfHealing"   # your CloudFormation stack name
INSIGHT_DIR="./devops-guru-insights"
CHAOS_HOST="${CHAOS_HOST:-http://localhost:5000}"
CHAOS_DURATION=300   # 5 minutes of chaos before we start the 15-minute wait

ts()  { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log() { echo "[$(ts)] $*"; }

# ---------------------------------------------------------------------------
# 1. Enable DevOps Guru — scope to the CloudFormation stack
#    (cheapest scope: only the resources you own are analysed)
# ---------------------------------------------------------------------------
cmd_enable() {
    log "=== Enabling DevOps Guru on stack: ${CFN_STACK_NAME} ==="

    # Update the resource collection to include our stack
    aws devops-guru update-resource-collection \
        --action ADD \
        --resource-collection "{
            \"CloudFormation\": {
                \"StackNames\": [\"${CFN_STACK_NAME}\"]
            }
        }" \
        --region "$REGION"

    log "Resource collection updated."

    # Enable CloudWatch Events / SNS notifications (optional but useful)
    # First check if a notification channel already exists
    existing=$(aws devops-guru list-notification-channels --region "$REGION" \
        --query "Channels[?Config.Sns.TopicArn!=null] | length(@)" --output text 2>/dev/null || echo 0)

    if [[ "$existing" -eq 0 ]]; then
        SNS_ARN=$(aws sns list-topics --region "$REGION" \
            --query "Topics[?contains(TopicArn,'TechStream-Alerts')].TopicArn | [0]" \
            --output text 2>/dev/null || echo "")

        if [[ -n "$SNS_ARN" && "$SNS_ARN" != "None" ]]; then
            aws devops-guru add-notification-channel \
                --config "{\"Sns\": {\"TopicArn\": \"${SNS_ARN}\"}}" \
                --region "$REGION"
            log "Notification channel wired to SNS: ${SNS_ARN}"
        else
            log "WARN: TechStream-Alerts SNS topic not found — skipping notification channel"
        fi
    else
        log "Notification channel already configured — skipping"
    fi

    # Enable AWS CodeGuru Profiler / CloudWatch integration (service integrations)
    aws devops-guru update-service-integration \
        --service-integration "{
            \"OpsCenter\": {\"OptInStatus\": \"ENABLED\"},
            \"LogsAnomalyDetection\": {\"OptInStatus\": \"ENABLED\"}
        }" \
        --region "$REGION" 2>/dev/null || \
        log "WARN: service-integration update returned an error (may not be supported in trial)"

    log "=== DevOps Guru enabled. Allow 15–30 min after first chaos run for insights to appear. ==="
}

# ---------------------------------------------------------------------------
# 2. Status — show current configuration
# ---------------------------------------------------------------------------
cmd_status() {
    log "=== DevOps Guru status ==="

    echo ""
    echo "--- Resource collection ---"
    aws devops-guru get-resource-collection \
        --resource-collection-type "AWS_CLOUD_FORMATION" \
        --region "$REGION" \
        --output json | jq '.ResourceCollection.CloudFormation'

    echo ""
    echo "--- Service integrations ---"
    aws devops-guru describe-service-integration \
        --region "$REGION" \
        --output json | jq '.ServiceIntegration'

    echo ""
    echo "--- Notification channels ---"
    aws devops-guru list-notification-channels \
        --region "$REGION" \
        --output json | jq '.Channels'
}

# ---------------------------------------------------------------------------
# 3. Chaos-and-wait — inject load chaos then poll for insights
# ---------------------------------------------------------------------------
cmd_chaos_and_wait() {
    log "=== PHASE 1: Injecting HTTP load chaos (${CHAOS_DURATION}s) against ${CHAOS_HOST} ==="

    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -f "${SCRIPT_DIR}/chaos.sh" ]]; then
        bash "${SCRIPT_DIR}/chaos.sh" load "$CHAOS_HOST" 200 "$CHAOS_DURATION"
    else
        log "WARN: chaos.sh not found — sending manual curl loop for ${CHAOS_DURATION}s"
        end=$(( $(date +%s) + CHAOS_DURATION ))
        while [[ $(date +%s) -lt $end ]]; do
            curl -s -o /dev/null "${CHAOS_HOST}/api" &
        done
        wait
    fi

    log "=== PHASE 2: Chaos complete. Waiting 15 minutes for DevOps Guru to analyse metrics... ==="

    # Count down visibly so the operator knows the script is alive
    for remaining in 14 13 12 11 10 9 8 7 6 5 4 3 2 1; do
        sleep 60
        log "  ${remaining} minute(s) remaining..."
    done
    sleep 60

    log "=== PHASE 3: 15-minute wait complete — running insight export ==="
    cmd_export
}

# ---------------------------------------------------------------------------
# 4. Export — list all insights and write each to a JSON file
# ---------------------------------------------------------------------------
cmd_export() {
    mkdir -p "$INSIGHT_DIR"
    log "=== Exporting DevOps Guru insights to ${INSIGHT_DIR}/ ==="

    # List reactive insights (triggered by anomalies) — most likely result of chaos
    local reactive_file="${INSIGHT_DIR}/reactive-insights-$(date -u +%Y%m%dT%H%M%S).json"
    aws devops-guru list-insights \
        --status-filter "{\"Any\": {\"Type\": \"REACTIVE\", \"StartTimeRange\": {\"FromTime\": $(( $(date +%s) - 86400 ))}}}" \
        --region "$REGION" \
        --output json > "$reactive_file" 2>/dev/null || \
    aws devops-guru list-insights \
        --status-filter '{"Any": {"Type": "REACTIVE"}}' \
        --region "$REGION" \
        --output json > "$reactive_file"

    log "Reactive insights written to ${reactive_file}"

    # Also list proactive insights (predicted before they become incidents)
    local proactive_file="${INSIGHT_DIR}/proactive-insights-$(date -u +%Y%m%dT%H%M%S).json"
    aws devops-guru list-insights \
        --status-filter '{"Any": {"Type": "PROACTIVE"}}' \
        --region "$REGION" \
        --output json > "$proactive_file" 2>/dev/null || true

    log "Proactive insights written to ${proactive_file}"

    # Drill into each reactive insight and save the full describe output
    local ids
    ids=$(jq -r '.ReactiveInsights[].Id' "$reactive_file" 2>/dev/null || echo "")

    if [[ -z "$ids" ]]; then
        log "No reactive insights found yet — wait longer after chaos or check DevOps Guru console"
        return 0
    fi

    echo ""
    log "Found reactive insight IDs: $(echo "$ids" | tr '\n' ' ')"

    while IFS= read -r insight_id; do
        [[ -z "$insight_id" ]] && continue
        local detail_file="${INSIGHT_DIR}/insight-${insight_id}.json"

        log "  Describing insight: ${insight_id}"
        aws devops-guru describe-insight \
            --id "$insight_id" \
            --region "$REGION" \
            --output json > "$detail_file"

        # Also grab the anomalies linked to this insight
        local anomaly_file="${INSIGHT_DIR}/anomalies-${insight_id}.json"
        aws devops-guru list-anomalies-for-insight \
            --insight-id "$insight_id" \
            --region "$REGION" \
            --output json > "$anomaly_file" 2>/dev/null || true

        # Print a human-readable summary
        echo ""
        echo "==========================================================="
        echo " Insight ID  : ${insight_id}"
        jq -r '"  Name       : " + .ReactiveInsight.Name,
               "  Severity   : " + .ReactiveInsight.Severity,
               "  Status     : " + .ReactiveInsight.Status,
               "  Start time : " + .ReactiveInsight.InsightTimeRange.StartTime'  \
            "$detail_file" 2>/dev/null || true
        echo " Detail file : ${detail_file}"
        echo "==========================================================="

    done <<< "$ids"

    log "=== Export complete. Files saved to ${INSIGHT_DIR}/ ==="
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
case "${1:-}" in
    enable)         cmd_enable         ;;
    status)         cmd_status         ;;
    chaos-and-wait) cmd_chaos_and_wait ;;
    export)         cmd_export         ;;
    *)
        echo "Usage: $0 {enable|status|chaos-and-wait|export}"
        echo ""
        echo "  enable          — scope DevOps Guru to the TechStream CFN stack"
        echo "  status          — show current resource collection & integrations"
        echo "  chaos-and-wait  — inject chaos, wait 15 min, then export insights"
        echo "  export          — list + describe all insights and save to JSON files"
        exit 1
        ;;
esac
