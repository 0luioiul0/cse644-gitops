#!/usr/bin/env bash
# Browser screenshots, for the evidence that is genuinely visual: the Argo CD
# application tree, a sync status, and the Grafana dashboard with data on it.
#
# Headless Chromium runs in a container with --network host, and --add-host
# maps every Ingress host name to the loopback address inside that container.
# That is how Host-header routing can be exercised from a real browser without
# editing /etc/hosts on the machine.
#
# Terminal output is the better evidence for anything numeric, and the other
# scripts produce it. These images exist because "the controller reports this
# application OutOfSync" is a claim a reader should be able to see.
set -uo pipefail
source "$(dirname "$0")/lib.sh"

SHOTS="$EVIDENCE/screenshots"
mkdir -p "$SHOTS"

shoot() {
    local name="$1" url="$2" budget="${3:-8000}" size="${4:-1600,1200}"
    echo "  $url"
    echo "     -> evidence/screenshots/${name}.png"
    docker run --rm --network host \
        --add-host "${WEB_HOST}:127.0.0.1" \
        --add-host "${API_HOST}:127.0.0.1" \
        --add-host "${ARGO_HOST}:127.0.0.1" \
        --add-host "${GRAFANA_HOST}:127.0.0.1" \
        --add-host "${PROM_HOST}:127.0.0.1" \
        -v "$SHOTS:/out" --entrypoint chromium-browser \
        zenika/alpine-chrome \
        --headless --disable-gpu --no-sandbox --hide-scrollbars \
        --window-size="${size}" --virtual-time-budget="${budget}" \
        --screenshot="/out/${name}.png" "$url" >/dev/null 2>&1
}

echo "Capturing screenshots..."
echo

echo "The applications:"
shoot "01-web-application"        "http://${WEB_HOST}:8090/"
shoot "02-api-application"        "http://${API_HOST}:8090/"

echo
echo "The GitOps controller:"
# The Argo CD UI is a single-page application; it needs longer than a static
# page before the tree has rendered.
shoot "03-argocd-applications"    "http://${ARGO_HOST}:8090/applications" 20000
shoot "04-argocd-platform-tree"   "http://${ARGO_HOST}:8090/applications/argocd/cse644-platform?view=tree&resource=" 20000
shoot "05-argocd-monitoring-tree" "http://${ARGO_HOST}:8090/applications/argocd/cse644-monitoring?view=tree&resource=" 20000

echo
echo "Monitoring:"
shoot "06-prometheus-targets"     "http://${PROM_HOST}:8090/targets" 15000
shoot "07-prometheus-graph"       "http://${PROM_HOST}:8090/graph?g0.expr=sum+by+(route)+(rate(cse644_api_requests_total%5B1m%5D))&g0.tab=0&g0.range_input=30m" 20000
shoot "08-grafana-dashboard"      "http://${GRAFANA_HOST}:8090/d/cse644-gitops/cse644-gitops-application-overview?orgId=1&from=now-30m&to=now&kiosk" 25000 "1600,1800"
shoot "09-grafana-dashboard-1h"   "http://${GRAFANA_HOST}:8090/d/cse644-gitops/cse644-gitops-application-overview?orgId=1&from=now-1h&to=now&kiosk" 25000 "1600,1800"

echo
ls -l "$SHOTS"
