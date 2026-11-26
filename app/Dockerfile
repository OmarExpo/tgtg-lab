# Small, non-root, cache-friendly Python image.
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app

# Dependencies first: this layer is only rebuilt when requirements.txt changes.
COPY requirements.txt .
RUN pip install -r requirements.txt

COPY main.py .

# Numeric UID so Kubernetes can verify runAsNonRoot.
RUN useradd --uid 10001 --no-create-home app
USER 10001

EXPOSE 8080

# ONE worker + threads on purpose: prometheus_client keeps metrics in process memory.
# With several worker processes each scrape would hit a random worker and counters
# would jump around (fixable with multiprocess mode, but that's another lesson).
# exec form -> gunicorn is PID 1 and receives SIGTERM from Kubernetes directly.
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "1", "--threads", "4", \
     "--graceful-timeout", "20", "--access-logfile", "-", "main:app"]
