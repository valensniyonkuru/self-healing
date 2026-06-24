#!/bin/bash
# chaos.sh — TechStream Self-Healing lab (Step 4)
# Injects two types of chaos against the local Flask app or a remote host.
#
# Usage:
#   ./chaos.sh cpu   [DURATION_SECS]          # Option A — CPU saturation
#   ./chaos.sh load  [HOST] [CONCURRENCY]     # Option B — HTTP error-rate spike
#   ./chaos.sh both  [HOST]                   # Run A then B sequentially
#
# Defaults:
#   DURATION_SECS = 300  (5 minutes)
#   HOST          = http://localhost:5000
#   CONCURRENCY   = 200
#
# Prerequisites (installed by userdata.sh):
#   Option A — stress-ng  (fallback: pure-bash yes-loop)
#   Option B — curl       (fallback: ab / apache bench if available)

set -euo pipefail

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
ts()  { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log() { echo "[$(ts)] $*"; }

require() {
    command -v "$1" &>/dev/null || { log "WARN: '$1' not found — will use fallback"; return 1; }
}

cleanup() {
    log "=== CLEANUP: killing background jobs ==="
    jobs -p | xargs -r kill 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
MODE="${1:-}"
DURATION="${2:-300}"
HOST="${2:-http://localhost:5000}"   # overridden per-mode below
CONCURRENCY="${3:-200}"

# ---------------------------------------------------------------------------
# Option A — CPU saturation
# ---------------------------------------------------------------------------
run_cpu_chaos() {
    local duration="${1:-300}"
    local cpus
    cpus=$(nproc)

    log "=== CHAOS START: CPU stress (${cpus} cores, ${duration}s) ==="

    if require stress-ng; then
        stress-ng --cpu "$cpus" --timeout "${duration}s" --metrics-brief &
        STRESS_PID=$!
        log "stress-ng PID=$STRESS_PID"
        wait "$STRESS_PID" || true
    else
        log "Falling back to yes-loop (one process per core)"
        local pids=()
        for (( i=0; i<cpus; i++ )); do
            yes > /dev/null &
            pids+=($!)
        done
        log "yes-loop PIDs: ${pids[*]}"
        sleep "$duration"
        kill "${pids[@]}" 2>/dev/null || true
    fi

    log "=== CHAOS STOP: CPU stress ended at $(ts) ==="
}

# ---------------------------------------------------------------------------
# Option B — HTTP load / error-rate spike
# ---------------------------------------------------------------------------
run_load_chaos() {
    local host="${1:-http://localhost:5000}"
    local concurrency="${2:-200}"
    local duration="${3:-300}"
    local endpoint="${host}/api"

    log "=== CHAOS START: HTTP load against ${endpoint} (concurrency=${concurrency}, duration=${duration}s) ==="

    local end_time=$(( $(date +%s) + duration ))
    local total=0 errors=0

    # --- inner loop: send one round of concurrent requests ---
    fire_round() {
        local responses
        # curl -s -o /dev/null -w "%{http_code}\n" runs silently and prints status
        responses=$(
            seq 1 "$concurrency" | xargs -P "$concurrency" -I{} \
                curl -s -o /dev/null -w "%{http_code}\n" \
                     --max-time 10 \
                     "$endpoint" 2>/dev/null
        )
        local round_total round_errors
        round_total=$(echo "$responses" | wc -l)
        round_errors=$(echo "$responses" | grep -c "^5" || true)
        total=$(( total + round_total ))
        errors=$(( errors + round_errors ))
        local pct=0
        [[ $total -gt 0 ]] && pct=$(( errors * 100 / total ))
        log "  round: total=${total} errors=${errors} error_rate=${pct}%"
    }

    # --- fallback: apache bench if xargs -P isn't available ---
    fire_round_ab() {
        local out
        out=$(ab -n "$concurrency" -c "$concurrency" -q "${endpoint}" 2>&1 || true)
        local fail
        fail=$(echo "$out" | grep -oP 'Non-2xx responses:\s*\K\d+' || echo 0)
        total=$(( total + concurrency ))
        errors=$(( errors + fail ))
        local pct=0
        [[ $total -gt 0 ]] && pct=$(( errors * 100 / total ))
        log "  ab round: total=${total} errors=${errors} error_rate=${pct}%"
    }

    # Choose firing method
    local fire_fn="fire_round"
    if ! require curl; then
        if require ab; then
            fire_fn="fire_round_ab"
        else
            log "ERROR: need curl or ab to run load chaos"
            exit 1
        fi
    fi

    # Keep firing rounds until time is up
    while [[ $(date +%s) -lt $end_time ]]; do
        $fire_fn
        sleep 2   # short pause between rounds so the metric scrape sees sustained load
    done

    local final_pct=0
    [[ $total -gt 0 ]] && final_pct=$(( errors * 100 / total ))
    log "=== CHAOS STOP: HTTP load ended — total=${total} errors=${errors} final_error_rate=${final_pct}% ==="
}

# ---------------------------------------------------------------------------
# Option: both (CPU then load)
# ---------------------------------------------------------------------------
run_both() {
    local host="${1:-http://localhost:5000}"
    log "=== CHAOS BOTH: running CPU (300 s) then HTTP load (300 s) ==="
    run_cpu_chaos 300
    run_load_chaos "$host" 200 300
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
case "$MODE" in
    cpu)
        DURATION="${2:-300}"
        run_cpu_chaos "$DURATION"
        ;;
    load)
        HOST="${2:-http://localhost:5000}"
        CONCURRENCY="${3:-200}"
        DURATION="${4:-300}"
        run_load_chaos "$HOST" "$CONCURRENCY" "$DURATION"
        ;;
    both)
        HOST="${2:-http://localhost:5000}"
        run_both "$HOST"
        ;;
    *)
        echo "Usage:"
        echo "  $0 cpu  [DURATION_SECS]"
        echo "  $0 load [HOST] [CONCURRENCY] [DURATION_SECS]"
        echo "  $0 both [HOST]"
        echo
        echo "Examples:"
        echo "  $0 cpu 300"
        echo "  $0 load http://localhost:5000 200 300"
        echo "  $0 both http://10.0.1.55:5000"
        exit 1
        ;;
esac
