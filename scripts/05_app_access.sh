#!/usr/bin/env bash
# Evidence 05: the application is running, reachable, and identifiable.
set -uo pipefail
source "$(dirname "$0")/lib.sh"

start_log "05-app-access"

step "Workloads"
run "kn get deploy,rs,pod -o wide"
run "kn get svc,ingress"

step "The web application through the ingress controller"
run "ing ${WEB_HOST} -i ${INGRESS}/ | sed -n '1,12p'"
run "ing ${WEB_HOST} ${INGRESS}/message"
run "ing ${WEB_HOST} ${INGRESS}/version"

step "Three replicas behind one Service"
note "Repeated calls to /whoami cycle through the Pods: this is kube-proxy"
note "balancing across the Deployment's replicas, not a cached page."
run "for i in 1 2 3 4 5 6; do ing ${WEB_HOST} ${INGRESS}/whoami; done | sort | uniq -c"

step "The api application through the same entry point, different Host header"
run "ing ${API_HOST} ${INGRESS}/api/info"

step "Identifiable as this student's work"
note "The heading comes from a ConfigMap in Git; the version comes from the"
note "image; the Pod name comes from the Downward API. All three appear in the"
note "response headers as well as the page."
run "ing ${WEB_HOST} -D - -o /dev/null ${INGRESS}/ | grep -i -e x-pod-name -e x-node-name -e x-app-"
run "ing ${API_HOST} -D - -o /dev/null ${INGRESS}/ | grep -i -e x-pod-name -e x-app-version"

step "The persistent volume, and the metric that reports it"
run "ing ${API_HOST} -X POST -d 'text=deployed by Argo CD from commit $(git -C "$ROOT" rev-parse --short HEAD)' ${INGRESS}/api/notes"
run "ing ${API_HOST} ${INGRESS}/api/notes"
run "ing ${API_HOST} ${INGRESS}/metrics | grep -e '^cse644_api_notes_stored' -e '^cse644_api_build_info'"

step "The metrics endpoint the whole observability stack is built on"
run "ing ${API_HOST} ${INGRESS}/metrics | grep '^# HELP'"

finish
