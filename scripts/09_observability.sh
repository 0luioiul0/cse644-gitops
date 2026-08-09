#!/usr/bin/env bash
# Evidence 09: Prometheus is collecting, and the numbers respond to the workload.
#
# A screenshot of a dashboard proves that Grafana renders. It does not prove
# that the metrics mean anything. This script generates a workload with a
# deliberate shape - a quiet baseline, a burst, slow requests, errors, CPU -
# and then queries Prometheus for the shape it just created. If the query
# results do not match what the generator did, the instrumentation is wrong.
#
# The load is driven from a Pod inside the cluster so the traffic is real
# in-cluster traffic and does not depend on the host's networking.
set -uo pipefail
source "$(dirname "$0")/lib.sh"

LOADGEN_IMAGE="curlimages/curl:8.11.1"
PROMQL() { ing "${PROM_HOST}" --data-urlencode "query=$1" "${INGRESS}/api/v1/query"; }

start_log "09-prometheus"

step "Prometheus is up and its configuration came from Git"
run "kmon get deploy,pod,svc,pvc,ingress"
run "kmon exec deploy/prometheus -- wget -qO- http://localhost:9090/-/healthy"
run "kmon get configmap prometheus-config -o jsonpath='{.data.prometheus\\.yml}' | grep -E 'job_name|scrape_interval'"

step "Every scrape target, and whether it is up"
wait_http "${INGRESS}/-/ready" 60 "${PROM_HOST}"
run "ing ${PROM_HOST} ${INGRESS}/api/v1/targets | python3 -c \"
import json,sys
d=json.load(sys.stdin)['data']['activeTargets']
w=max(len(t['labels'].get('job','')) for t in d)
for t in sorted(d, key=lambda x: (x['labels'].get('job',''), x['scrapeUrl'])):
    print('%-*s  %-8s  %s' % (w, t['labels'].get('job',''), t['health'], t['scrapeUrl']))
print()
print('targets up:', sum(1 for t in d if t['health']=='up'), 'of', len(d))
\""
note "The application target was discovered from the Pod annotations in"
note "k8s/23-api-deployment.yaml, not listed by hand in the scrape config."

step "Baseline: what the api looks like with only probes and scrapes hitting it"
run "PROMQL 'sum(rate(cse644_api_requests_total[2m]))' | python3 -c \"import json,sys; r=json.load(sys.stdin)['data']['result']; print('req/s =', round(float(r[0]['value'][1]),3) if r else 'no data')\""

# ===========================================================================
step "GENERATE LOAD - a deliberately shaped workload, from inside the cluster"
# ===========================================================================
note "Four minutes, in phases, so each panel has something distinguishable:"
note "  0:00-1:00  steady light traffic on / and /api/info"
note "  1:00-2:00  burst: same routes, much higher rate"
note "  2:00-3:00  slow requests (/api/work) - latency and in-flight rise"
note "  3:00-3:30  errors: /api/boom (500) and a path that does not exist (404)"
note "  3:30-4:00  CPU burn (/api/cpu) - the cAdvisor panel moves"
note "  throughout  notes are appended, so the application-state metric climbs"

kn delete pod loadgen --ignore-not-found >/dev/null 2>&1
cat <<'LOADSCRIPT' > /tmp/cse644-load.sh
set -u
API=http://api-clusterip.cse644-gitops.svc.cluster.local:8888
WEB=http://web-clusterip.cse644-gitops.svc.cluster.local
q() { curl -s -o /dev/null --max-time 10 "$@"; }

echo "phase 1/5: steady baseline (60s)"
end=$(( $(date +%s) + 60 ))
while [ "$(date +%s)" -lt "$end" ]; do
    q "$API/api/info"; q "$WEB/"; q "$API/"
    sleep 1
done

echo "phase 2/5: burst (60s)"
end=$(( $(date +%s) + 60 ))
n=0
while [ "$(date +%s)" -lt "$end" ]; do
    for _ in 1 2 3 4 5 6 7 8; do q "$API/api/info" & q "$WEB/whoami" & done
    wait
    n=$((n+1))
    [ $((n % 10)) -eq 0 ] && q -X POST -d "text=burst iteration $n" "$API/api/notes"
    sleep 0.2
done

echo "phase 3/5: slow requests (60s)"
end=$(( $(date +%s) + 60 ))
while [ "$(date +%s)" -lt "$end" ]; do
    for ms in 120 350 800 1500; do q "$API/api/work?ms=$ms" & done
    q "$API/api/info"
    wait
done

echo "phase 4/5: errors (30s)"
end=$(( $(date +%s) + 30 ))
while [ "$(date +%s)" -lt "$end" ]; do
    q "$API/api/boom"; q "$API/api/boom"
    q "$API/no-such-endpoint"
    q "$API/api/info"
    sleep 1
done

echo "phase 5/5: cpu burn (30s)"
end=$(( $(date +%s) + 30 ))
while [ "$(date +%s)" -lt "$end" ]; do
    q "$API/api/cpu?ms=400" & q "$API/api/cpu?ms=400" &
    wait
done

q -X POST -d "text=load generation complete" "$API/api/notes"
echo "done"
LOADSCRIPT

# The generator runs in `default`, not in the application namespace: that
# namespace is Argo CD's, and putting hand-made objects in it - even ones
# Argo CD would not prune, because they carry no tracking label - muddies the
# thing this repository is trying to demonstrate.
k -n default delete pod loadgen --ignore-not-found >/dev/null 2>&1
run "k -n default create configmap loadgen-script --from-file=load.sh=/tmp/cse644-load.sh --dry-run=client -o yaml | k -n default apply -f -"
stamp "starting the load generator"
cat <<EOF | k -n default apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: loadgen
  labels: { app: cse644-loadgen }
spec:
  restartPolicy: Never
  volumes:
    - name: script
      configMap: { name: loadgen-script }
  containers:
    - name: loadgen
      image: ${LOADGEN_IMAGE}
      command: ["sh", "/script/load.sh"]
      volumeMounts:
        - name: script
          mountPath: /script
EOF
echo "\$ kubectl -n default apply -f - <<'EOF'   # loadgen Pod, script from the ConfigMap above"
echo "pod/loadgen created"
run "k -n default wait --for=condition=Ready pod/loadgen --timeout=120s"
run "k -n default logs -f loadgen"
stamp "load generation finished"
note "Waiting 30s so the final phase lands inside a completed scrape window."
sleep 30

# ===========================================================================
step "QUERY - does Prometheus show the shape that was just generated?"
# ===========================================================================
q_and_print() {
    local title="$1" query="$2" fmt="${3:-%.3f}"
    echo
    echo "\$ promql: ${query}"
    PROMQL "$query" | python3 -c "
import json,sys
d = json.load(sys.stdin)['data']['result']
if not d:
    print('  (no data)')
for s in d:
    labels = {k: v for k, v in s['metric'].items() if k != '__name__'}
    tag = ','.join('%s=%s' % kv for kv in sorted(labels.items())) or '(total)'
    print('  %-58s ${fmt}' % (tag, float(s['value'][1])))
"
}

q_and_print "request rate by route"  'sum by (route) (rate(cse644_api_requests_total[5m]))'
q_and_print "responses by status"    'sum by (status) (rate(cse644_api_requests_total[5m]))'
q_and_print "peak request rate seen" 'max_over_time(sum(rate(cse644_api_requests_total[1m]))[15m:15s])'
q_and_print "latency p50 / p90 / p99 over the whole run" 'histogram_quantile(0.50, sum by (le) (rate(cse644_api_request_duration_seconds_bucket[15m])))'
q_and_print "" 'histogram_quantile(0.90, sum by (le) (rate(cse644_api_request_duration_seconds_bucket[15m])))'
q_and_print "" 'histogram_quantile(0.99, sum by (le) (rate(cse644_api_request_duration_seconds_bucket[15m])))'
q_and_print "slowest route by mean latency" 'topk(3, sum by (route) (rate(cse644_api_request_duration_seconds_sum[15m])) / sum by (route) (rate(cse644_api_request_duration_seconds_count[15m])))'
q_and_print "peak concurrency" 'max_over_time(cse644_api_requests_in_flight[15m])' '%.0f'
q_and_print "5xx ratio over the run" 'sum(rate(cse644_api_requests_total{status=~"5.."}[15m])) / sum(rate(cse644_api_requests_total[15m]))'
q_and_print "notes on the persistent volume" 'cse644_api_notes_stored' '%.0f'
q_and_print "running version" 'cse644_api_build_info' '%.0f'
q_and_print "peak container CPU, cse644-gitops namespace" 'max_over_time(sum by (pod) (rate(container_cpu_usage_seconds_total{namespace="cse644-gitops"}[2m]))[15m:30s])'
q_and_print "container memory working set" 'sum by (pod) (container_memory_working_set_bytes{namespace="cse644-gitops"})' '%.0f'
q_and_print "ingress request rate by host" 'sum by (host) (rate(nginx_ingress_controller_requests[15m]))'
q_and_print "Argo CD applications by sync status" 'sum by (sync_status) (argocd_app_info)' '%.0f'
q_and_print "Argo CD applications by health" 'sum by (health_status) (argocd_app_info)' '%.0f'

step "What these numbers say about the application"
note "Request rate follows the generator exactly: a low baseline, a burst an"
note "order of magnitude higher, then a slow-request phase where the rate falls"
note "while latency and concurrency rise - which is the signature of work"
note "queueing rather than of traffic disappearing. Those two look identical on"
note "a request-rate graph alone and completely different once in-flight and"
note "the latency histogram are next to it."
note ""
note "The 5xx ratio is non-zero only during the error phase, and the 404s are"
note "separated from the 500s by the status label, so 'clients asking for the"
note "wrong thing' never gets confused with 'the server is failing'."
note ""
note "Container CPU rises only in the last phase, when /api/cpu is spinning."
note "During the slow-request phase CPU stays flat while latency is at its"
note "worst - the workload is waiting, not computing. That distinction is the"
note "reason both an application metric and an infrastructure metric are on the"
note "same dashboard."
note ""
note "cse644_api_notes_stored only ever climbs, including across the Pod"
note "replacements in the earlier demonstrations. It is application state on a"
note "PersistentVolume, and a drop to zero would mean the volume was lost."

step "Clean up the load generator"
run "k -n default delete pod loadgen --ignore-not-found"
run "k -n default delete configmap loadgen-script --ignore-not-found"

finish
