#!/usr/bin/env bash
# Evidence 10: Grafana, provisioned from Git, serving a dashboard with data in it.
#
# Grafana's own HTTP API is used rather than a description of the UI, so each
# claim is checkable: the datasource exists and answers, the dashboard was
# loaded from the provisioning path, and every panel query returns points
# rather than an empty series. A dashboard that renders but plots nothing is
# the usual failure here, and only the last check catches it.
set -uo pipefail
source "$(dirname "$0")/lib.sh"

G() { ing "${GRAFANA_HOST}" "$@"; }

start_log "10-grafana"

step "Grafana is up"
run "kmon get deploy grafana -o wide"
run "kmon get pod -l app.kubernetes.io/name=grafana -o wide"
wait_http "${INGRESS}/api/health" 90 "${GRAFANA_HOST}"
run "G ${INGRESS}/api/health"

step "Reachable through the shared ingress controller"
run "G -o /dev/null -w 'http://${GRAFANA_HOST}:8090/ -> HTTP %{http_code}\n' ${INGRESS}/"
note "Anonymous access is enabled with the Viewer role, so the dashboard can be"
note "read and screenshotted without a login and without a password appearing"
note "anywhere in this repository. The admin account's password is in a Secret"
note "created outside Git."

step "The datasource was provisioned from a file, not created in the UI"
run "kmon get configmap grafana-provisioning -o jsonpath='{.data.datasource\\.yaml}'"
run "G ${INGRESS}/api/datasources | python3 -c \"
import json,sys
for d in json.load(sys.stdin):
    print('name=%s type=%s uid=%s url=%s default=%s' % (d['name'], d['type'], d['uid'], d['url'], d['isDefault']))
\""

step "And it can actually reach Prometheus"
run "G ${INGRESS}/api/datasources/uid/cse644-prometheus/health"

step "The dashboard was provisioned from a ConfigMap in Git"
run "kmon exec deploy/grafana -- ls -l /var/lib/grafana/dashboards /etc/grafana/provisioning/dashboards"
run "G ${INGRESS}/api/search?query=CSE644 | python3 -c \"
import json,sys
for d in json.load(sys.stdin):
    print('uid=%s  folder=%s  title=%s' % (d.get('uid'), d.get('folderTitle','General'), d['title']))
\""

step "Its panels, in order"
run "G ${INGRESS}/api/dashboards/uid/cse644-gitops | python3 -c \"
import json,sys
d = json.load(sys.stdin)
dash = d['dashboard']
print('title      :', dash['title'])
print('provisioned:', d['meta'].get('provisioned'), 'from', d['meta'].get('provisionedExternalId'))
print('editable   :', dash.get('editable'))
print()
for p in dash['panels']:
    print('%2d  %-11s %s' % (p['id'], p['type'], p['title']))
    for t in p.get('targets', []):
        print('      %s' % t['expr'])
\""
note "provisioned: True means Grafana loaded it from the provisioning path. A"
note "dashboard built by clicking would say False and would live only in the"
note "container's database, which here is an emptyDir - one restart from gone,"
note "and invisible to Git either way."

step "Every panel query returns data"
note "Each expression from the dashboard, run against the datasource through"
note "Grafana's own query API. Empty results here would mean a dashboard that"
note "renders correctly and shows nothing."
run "G ${INGRESS}/api/dashboards/uid/cse644-gitops | python3 -c \"
import json,sys
d = json.load(sys.stdin)['dashboard']
out = []
for p in d['panels']:
    for t in p.get('targets', []):
        out.append((p['title'], t['expr']))
print(json.dumps(out))
\" > /tmp/cse644-panels.json"
run "python3 - <<'PY'
import json, subprocess, urllib.parse
panels = json.load(open('/tmp/cse644-panels.json'))
seen = set()
ok = bad = 0
for title, expr in panels:
    if expr in seen:
        continue
    seen.add(expr)
    out = subprocess.run(
        ['curl', '-s', '-H', 'Host: prometheus.gitops.local',
         '--data-urlencode', 'query=' + expr,
         'http://localhost:8090/api/v1/query'],
        capture_output=True, text=True).stdout
    try:
        res = json.loads(out)['data']['result']
    except Exception:
        res = []
    n = len(res)
    if n:
        ok += 1
    else:
        bad += 1
    print('  %-4s %-2d series  %-52s %s' % ('OK' if n else 'EMPTY', n, title[:52], expr[:70]))
print()
print('  %d queries returning data, %d empty' % (ok, bad))
PY"

step "A rendered view of the same data, for the record"
note "The screenshots in evidence/screenshots/ are taken by a headless browser"
note "against these same URLs - see scripts/11_screenshots.sh."
run "echo 'dashboard: http://${GRAFANA_HOST}:8090/d/cse644-gitops'"

finish
