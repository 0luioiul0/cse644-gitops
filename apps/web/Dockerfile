# CSE644 Assignment 03 - customized web workload (Nginx).
#
# Carried forward from Assignment 02 unchanged in substance: the visible
# message still comes from the environment, fed by a ConfigMap. What is new is
# that the ConfigMap is now declared in Git and applied by Argo CD, so the
# demonstration in this assignment is "edit a file, push, watch the page
# change" rather than "kubectl apply".
#
# This workload is deliberately not instrumented with its own /metrics
# endpoint. Its HTTP traffic is measured at the ingress controller instead -
# see monitoring/11-prometheus-config.yaml and the README's observability
# section for why that is the better place for it.
FROM nginx:1.27.5-alpine

ARG APP_VERSION=0.0.0-dev

LABEL org.opencontainers.image.title="cse644-gitops-web" \
      org.opencontainers.image.description="Customized Nginx workload for CSE644 Assignment 03" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.source="https://github.com/0luioiul0/cse644-gitops" \
      course="CSE644 Cloud Computing"

# Defaults, so the image also runs standalone under plain `docker run`.
# In Kubernetes these are overridden from a ConfigMap and the Downward API.
ENV APP_MESSAGE="Customized Nginx, deployed by Argo CD from Git." \
    APP_ENV="local" \
    APP_VERSION=${APP_VERSION} \
    POD_NAME="standalone" \
    NODE_NAME="standalone"

RUN rm -rf /usr/share/nginx/html/*
COPY site/ /usr/share/nginx/html/

# Placed in templates/, not conf.d/: the stock entrypoint runs envsubst over
# this file at container start and writes the result to /etc/nginx/conf.d/.
COPY default.conf.template /etc/nginx/templates/default.conf.template

EXPOSE 80
