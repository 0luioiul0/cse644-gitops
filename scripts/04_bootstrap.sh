#!/usr/bin/env bash
# Evidence 04: hand Git the cluster.
#
# Two `kubectl apply` calls, and they are the last two in this repository. From
# here on the only way to change the cluster is to change Git.
set -uo pipefail
source "$(dirname "$0")/lib.sh"

start_log "04-gitops-deploy"

step "Credentials that are deliberately NOT in Git"
note "A Kubernetes Secret is base64-encoded, not encrypted. Committing one to a"
note "public repository publishes it. Both Secrets below are generated here and"
note "never leave the cluster; only their key names and lengths are printed."
note "The honest cost: these two objects are outside GitOps control, so Argo CD"
note "can neither recreate them nor detect drift in them. Sealed Secrets or the"
note "External Secrets Operator is the production answer - see the README."
run "k create namespace ${NS} --dry-run=client -o yaml | k apply -f -"
run "k create namespace ${MON_NS} --dry-run=client -o yaml | k apply -f -"
if kn get secret api-secret >/dev/null 2>&1; then
    note "api-secret already exists; leaving it in place"
else
    kn create secret generic api-secret --from-literal=API_KEY="$(openssl rand -hex 24)" >/dev/null
    echo "\$ kubectl -n ${NS} create secret generic api-secret --from-literal=API_KEY=\"\$(openssl rand -hex 24)\""
    echo "secret/api-secret created"
fi
if kmon get secret grafana-admin >/dev/null 2>&1; then
    note "grafana-admin already exists; leaving it in place"
else
    kmon create secret generic grafana-admin --from-literal=admin-password="$(openssl rand -hex 18)" >/dev/null
    echo "\$ kubectl -n ${MON_NS} create secret generic grafana-admin --from-literal=admin-password=\"\$(openssl rand -hex 18)\""
    echo "secret/grafana-admin created"
fi
run "kn describe secret api-secret | tail -5"
run "kmon describe secret grafana-admin | tail -5"

step "Bootstrap 1 of 2: the AppProject"
note "Argo CD will not admit an Application whose project does not exist, and"
note "the project is declared inside the directory the root Application syncs."
note "Applying it once by hand breaks that circle; the copy in gitops/apps/ is"
note "then the managed one."
run "k apply -f ${ROOT}/gitops/apps/00-project.yaml"
run "argo proj get cse644"

step "Bootstrap 2 of 2: the root Application"
run "k apply -f ${ROOT}/gitops/bootstrap/02-root-app.yaml"

step "The root Application creates its children, which create everything else"
wait_app cse644-root Synced Healthy 120
run "argo app list -o wide"

step "Wait for the platform and monitoring Applications to converge"
wait_app cse644-platform Synced Healthy 180
wait_app cse644-monitoring Synced Healthy 300
run "argo app get cse644-platform"
run "argo app get cse644-monitoring"

step "What Argo CD created - the whole tree, from one applied file"
run "argo app resources cse644-platform"
run "argo app resources cse644-monitoring"
run "kn get all,ingress,pvc,configmap -o wide | grep -v '^configmap/kube-root-ca'"
run "kmon get all,ingress,pvc -o wide"

step "Every object Argo CD created carries a tracking annotation"
note "This is how prune knows what it owns. Argo CD v3 tracks by annotation"
note "rather than by the app.kubernetes.io/instance label it used historically,"
note "and the difference matters here: the annotation records the application"
note "name, the group and kind, and the namespace and name, so the controller"
note "can distinguish an object it created from an identically-named object it"
note "merely found. A label carrying only an application name cannot, and it"
note "also collides with the perfectly ordinary app.kubernetes.io/instance the"
note "workload itself might want to set."
run "kn get deploy,svc,ingress,cm -o custom-columns='KIND:.kind,NAME:.metadata.name,TRACKED-BY:.metadata.annotations.argocd\.argoproj\.io/tracking-id'"
note "And the two Secrets created by hand, for contrast. No annotation, so the"
note "controller does not consider them its own and prune will never touch"
note "them - which is the reason this deployment survives having its only"
note "credentials outside Git."
run "kn get secret api-secret -o custom-columns='NAME:.metadata.name,TRACKED-BY:.metadata.annotations.argocd\.argoproj\.io/tracking-id'"
run "kmon get secret grafana-admin -o custom-columns='NAME:.metadata.name,TRACKED-BY:.metadata.annotations.argocd\.argoproj\.io/tracking-id'"

step "Nothing was applied by hand except the two bootstrap files"
run "argo app get cse644-platform -o json | python3 -c \"import json,sys; a=json.load(sys.stdin); print('source :', a['spec']['source']['repoURL'], a['spec']['source']['path'], '@', a['spec']['source']['targetRevision']); print('synced :', a['status']['sync']['status'], 'at revision', a['status']['sync']['revision'][:8]); print('health :', a['status']['health']['status'])\""

finish
