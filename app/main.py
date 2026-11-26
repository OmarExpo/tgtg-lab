"""bags-api: a tiny 'Too Good To Go'-style service used to practise Kubernetes,
GitOps and observability.

Endpoints
  GET /bags     -> business endpoint (instrumented, supports failure injection)
  GET /work     -> burns CPU on purpose (to trigger the HPA)
  GET /healthz  -> liveness: "is the process alive?"
  GET /readyz   -> readiness: "can I take traffic right now?"
  GET /metrics  -> Prometheus scrape endpoint

Failure injection (set as env vars in the Deployment, via Git):
  ERROR_RATE=0.3      -> 30 % of /bags calls return HTTP 500
  EXTRA_LATENCY=0.8   -> every /bags call sleeps 0.8 s first
  NOT_READY=true      -> /readyz returns 503 (pod stays Running but gets no traffic)
"""
import hashlib
import os
import random
import time

from flask import Flask, Response, jsonify
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest

app = Flask(__name__)

# --- Metrics -----------------------------------------------------------------
# Counter  = only goes up (requests served). Query it with rate().
# Histogram = buckets of observed values (latency). Query with histogram_quantile().
# Labels must have LOW cardinality: path + status code, never user ids or full URLs.
REQUESTS = Counter("http_requests_total", "HTTP requests served", ["path", "status"])
LATENCY = Histogram(
    "http_request_duration_seconds",
    "Request latency in seconds",
    ["path"],
    buckets=(0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5),
)

ERROR_RATE = float(os.getenv("ERROR_RATE", "0"))
EXTRA_LATENCY = float(os.getenv("EXTRA_LATENCY", "0"))
NOT_READY = os.getenv("NOT_READY", "false").lower() == "true"
VERSION = os.getenv("APP_VERSION", "dev")

STORES = ["Bakery Nørrebro", "Sushi Vesterbro", "Netto Østerbro", "Café Frederiksberg"]


@app.get("/healthz")
def healthz():
    return "ok"


@app.get("/readyz")
def readyz():
    if NOT_READY:
        return "not ready", 503
    return "ready"


@app.get("/bags")
def bags():
    start = time.perf_counter()
    if EXTRA_LATENCY:
        time.sleep(EXTRA_LATENCY)
    if random.random() < ERROR_RATE:
        status, body = 500, {"error": "injected failure"}
    else:
        status, body = 200, {
            "store": random.choice(STORES),
            "bags_left": random.randint(0, 5),
            "version": VERSION,
        }
    REQUESTS.labels("/bags", str(status)).inc()
    LATENCY.labels("/bags").observe(time.perf_counter() - start)
    return jsonify(body), status


@app.get("/work")
def work():
    """Burn ~CPU for a short while so the HorizontalPodAutoscaler has a reason to scale."""
    start = time.perf_counter()
    data = b"food-waste"
    for _ in range(20000):
        data = hashlib.sha256(data).digest()
    REQUESTS.labels("/work", "200").inc()
    LATENCY.labels("/work").observe(time.perf_counter() - start)
    return jsonify(done=True)


@app.get("/metrics")
def metrics():
    return Response(generate_latest(), mimetype=CONTENT_TYPE_LATEST)


if __name__ == "__main__":  # local run without gunicorn: python main.py
    app.run(host="0.0.0.0", port=8080)
