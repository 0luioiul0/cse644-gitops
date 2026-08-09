# CSE644 Assignment 03 - Python application workload, port 8888.
#
# The Assignment 02 image with a /metrics endpoint added. The version is a
# build argument rather than a hard-coded string so the tag pushed to the
# registry, the OCI label, and the value the running process reports through
# /metrics and /api/info can never disagree - which matters here, because the
# whole point of the GitOps demonstration is being able to say with certainty
# which build is running.
FROM python:3.12.13-alpine

ARG APP_VERSION=0.0.0-dev

LABEL org.opencontainers.image.title="cse644-gitops-api" \
      org.opencontainers.image.description="Instrumented Python workload on port 8888 for CSE644 Assignment 03" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.source="https://github.com/0luioiul0/cse644-gitops" \
      course="CSE644 Cloud Computing"

ENV PORT=8888 \
    DATA_DIR=/data \
    APP_VERSION=${APP_VERSION} \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

WORKDIR /app
COPY app.py .

# Run unprivileged. The uid is fixed so the PersistentVolume can be owned by it
# through the Pod's fsGroup.
RUN adduser -D -u 10001 appuser \
 && mkdir -p /data \
 && chown -R appuser:appuser /app /data
USER 10001

EXPOSE 8888

CMD ["python", "app.py"]
