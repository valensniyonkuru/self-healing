# app.py — TechStream buggy Flask web server
# Exposes /health, /api (with injected failures), and /metrics endpoints.
# Logs every request as a JSON line to stdout so the CloudWatch agent can tail it.

import json
import logging
import random
import sys
import time
from collections import defaultdict
from threading import Lock

from flask import Flask, jsonify, request, Response

# ---------------------------------------------------------------------------
# Logging — emit one JSON object per line so CloudWatch Log Insights can parse
# ---------------------------------------------------------------------------
class JsonFormatter(logging.Formatter):
    def format(self, record):
        log_record = {
            "timestamp": self.formatTime(record, "%Y-%m-%dT%H:%M:%S"),
            "level": record.levelname,
            "message": record.getMessage(),
        }
        if hasattr(record, "extra"):
            log_record.update(record.extra)
        return json.dumps(log_record)


handler = logging.StreamHandler(sys.stdout)
handler.setFormatter(JsonFormatter())
logger = logging.getLogger("techstream")
logger.setLevel(logging.INFO)
logger.addHandler(handler)
logger.propagate = False

# ---------------------------------------------------------------------------
# In-memory counters (reset on restart — good enough for a lab)
# ---------------------------------------------------------------------------
_lock = Lock()
_counters: dict[str, float] = defaultdict(float)


def _inc(key: str, value: float = 1.0) -> None:
    with _lock:
        _counters[key] += value


def _get(key: str) -> float:
    with _lock:
        return _counters[key]


# ---------------------------------------------------------------------------
# Flask application
# ---------------------------------------------------------------------------
app = Flask(__name__)

# Failure probability and latency bounds (tweak for demos)
ERROR_RATE     = 0.30          # 30 % of /api calls return 500
MIN_LATENCY_S  = 0.50          # 500 ms minimum
MAX_LATENCY_S  = 3.00          # 3 s maximum


@app.before_request
def _before():
    request._start_time = time.monotonic()


@app.after_request
def _after(response):
    duration_ms = (time.monotonic() - request._start_time) * 1000
    _inc("requests_total")
    if response.status_code >= 500:
        _inc("errors_total")
    _inc("latency_total_ms", duration_ms)

    logger.info(
        "request",
        extra={
            "method":      request.method,
            "path":        request.path,
            "status":      response.status_code,
            "duration_ms": round(duration_ms, 2),
            "remote_addr": request.remote_addr,
        },
    )
    return response


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------

@app.route("/health")
def health():
    """Liveness probe — always returns 200."""
    return jsonify(status="ok"), 200


@app.route("/api")
def api():
    """Intentionally buggy endpoint: 30 % HTTP 500, random latency 0.5–3 s."""
    latency = random.uniform(MIN_LATENCY_S, MAX_LATENCY_S)
    time.sleep(latency)

    if random.random() < ERROR_RATE:
        return jsonify(error="internal server error", latency_ms=round(latency * 1000, 2)), 500

    return jsonify(message="success", latency_ms=round(latency * 1000, 2)), 200


@app.route("/metrics")
def metrics():
    """
    Prometheus-style text exposition (no library dependency).
    The CloudWatch agent's procstat/prometheus scraper can consume this,
    or you can parse it with a custom script.
    """
    total    = _get("requests_total")
    errors   = _get("errors_total")
    lat_ms   = _get("latency_total_ms")
    avg_lat  = (lat_ms / total) if total else 0.0
    err_rate = (errors / total * 100) if total else 0.0

    lines = [
        "# HELP techstream_requests_total Total HTTP requests served",
        "# TYPE techstream_requests_total counter",
        f'techstream_requests_total{{app="techstream"}} {int(total)}',
        "",
        "# HELP techstream_errors_total Total HTTP 5xx responses",
        "# TYPE techstream_errors_total counter",
        f'techstream_errors_total{{app="techstream"}} {int(errors)}',
        "",
        "# HELP techstream_error_rate_percent Percentage of requests resulting in 5xx",
        "# TYPE techstream_error_rate_percent gauge",
        f'techstream_error_rate_percent{{app="techstream"}} {round(err_rate, 4)}',
        "",
        "# HELP techstream_avg_latency_ms Average request latency in milliseconds",
        "# TYPE techstream_avg_latency_ms gauge",
        f'techstream_avg_latency_ms{{app="techstream"}} {round(avg_lat, 2)}',
        "",
    ]

    return Response("\n".join(lines), mimetype="text/plain; version=0.0.4")


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    logger.info("startup", extra={"port": 5000, "error_rate": ERROR_RATE})
    # threaded=True so concurrent requests are handled (needed for load tests)
    app.run(host="0.0.0.0", port=5000, threaded=True)
