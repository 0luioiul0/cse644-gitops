#!/usr/bin/env bash
# Evidence 11: remove this assignment's resources, and verify nothing is left.
#
# The removal is done the same way everything else was: through Argo CD. The
# root Application carries the resources-finalizer annotation, so deleting it
# cascades - children first, then their objects, then the namespaces those
# objects live in. Deleting the Application without that finalizer would orphan
# everything it created, which is the usual way a "cleaned up" cluster ends up
# still running the workload.
#
#   bash scripts/cleanup.sh              remove the assignment, keep Argo CD
#   bash scripts/cleanup.sh --all        also remove Argo CD itself
#
# What this script deliberately does NOT touch: the KinD cluster, ingress-nginx,
# MetalLB, and the `cse644` namespace belonging to Assignment 02. Other people's
# containers are running on this Docker host, so nothing here calls
# `docker system prune` either.
set -uo pipefail
source "$(dirname "$0")/lib.sh"

REMOVE_ARGOCD=false
[ "${1:-}" = "--all" ] && REMOVE_ARGOCD=true

start_log "11-cleanup"

step "Before: what exists"
run "argo app list -o wide"
run "k get ns | grep -e cse644 -e argocd"
run "kn get all,ingress,pvc 2>/dev/null | head -20"
run "kmon get all,ingress,pvc 2>/dev/null | head -20"

step "Delete the root Application; the cascade does the rest"
note "One object. Its finalizer removes the two child Applications, whose"
note "finalizers remove every object those Applications created - including"
note "the two namespaces, because the namespaces are themselves manifests in"
note "the repository."
run "kargo delete application cse644-root --wait=true --timeout=300s"

step "Wait for the children and their objects to go"
for i in $(seq 1 60); do
    LEFT=$(kargo get applications --no-headers 2>/dev/null | wc -l)
    NS_LEFT=$(k get ns --no-headers 2>/dev/null | grep -c -e '^cse644-gitops' -e '^cse644-monitoring')
    stamp "applications=${LEFT}  namespaces=${NS_LEFT}"
    [ "$LEFT" = "0" ] && [ "$NS_LEFT" = "0" ] && break
    sleep 5
done

step "Remove the AppProject and the Argo CD ingress"
note "Both were applied by hand during bootstrap, so neither is owned by an"
note "Application and neither is removed by the cascade."
note "Order matters, and getting it wrong deadlocks the cluster. An Application"
note "carrying the resources-finalizer cannot finish deleting unless the"
note "controller can still resolve its AppProject; delete the project first and"
note "the Application hangs in Terminating forever, the project hangs on its own"
note "finalizer waiting for the Application, and the only way out is to patch"
note "the finalizers off both by hand. Hence the wait loop above, and the guard"
note "below: the project is only removed once every Application is actually"
note "gone."
note "The same deadlock used to be unavoidable, because the project lived in"
note "gitops/apps/ and was therefore managed by the root Application - which"
note "also referenced it. Deleting the root required deleting the project,"
note "deleting the project required no Application to reference it, and the"
note "referencing Application was the root. It now lives in gitops/bootstrap/,"
note "outside anything Argo CD manages, so the cascade can complete."
LEFT=$(kargo get applications --no-headers 2>/dev/null | wc -l)
if [ "$LEFT" = "0" ]; then
    run "kargo delete appproject cse644 --ignore-not-found"
else
    echo
    echo "[refusing to delete the AppProject: ${LEFT} Application(s) still present]"
    run "kargo get applications"
    note "Deleting the project now would strand them. Re-run this script once"
    note "they have finished terminating."
fi
run "kargo delete ingress argocd-server --ignore-not-found"

if $REMOVE_ARGOCD; then
    step "Remove Argo CD itself"
    run "k delete -n ${ARGO_NS} -f https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml --ignore-not-found | tail -5"
    run "k delete namespace ${ARGO_NS} --ignore-not-found --timeout=300s"
    note "And the kube context the CLI used, so the kubeconfig is left as it"
    note "was found."
    run "kubectl config delete-context ${ARGO_KUBE_CONTEXT} || true"
fi

# ===========================================================================
step "VERIFY - the checks that would fail if anything survived"
# ===========================================================================
run "k get ns"
run_expect_fail "k get ns ${NS}"
run_expect_fail "k get ns ${MON_NS}"

note "Namespaced objects: gone with their namespaces."
run "k get all -A 2>/dev/null | grep -e cse644-gitops -e cse644-monitoring || echo 'no workloads remain'"

note "Cluster-scoped objects do NOT go with a namespace. The ClusterRole and"
note "ClusterRoleBinding Prometheus needed are the ones that would be left"
note "behind by a namespace-only cleanup, so they are checked by name."
run "k get clusterrole,clusterrolebinding | grep cse644 || echo 'no cluster-scoped leftovers'"

note "PersistentVolumes are cluster-scoped too. Their claims were deleted with"
note "the namespaces; the StorageClass reclaim policy is Delete, so the volumes"
note "follow. Anything Released or Available here would be a leak."
run "k get pv | grep -e cse644-gitops -e cse644-monitoring || echo 'no volumes remain'"

note "The two Secrets that were never in Git went with their namespaces."
run "k get secret -A 2>/dev/null | grep -e api-secret -e grafana-admin || echo 'no secrets remain'"

note "The ingress host names no longer resolve to a backend."
run "ing ${WEB_HOST} -o /dev/null -w 'web.gitops.local      -> HTTP %{http_code}\n' ${INGRESS}/"
run "ing ${API_HOST} -o /dev/null -w 'api.gitops.local      -> HTTP %{http_code}\n' ${INGRESS}/"
run "ing ${GRAFANA_HOST} -o /dev/null -w 'grafana.gitops.local  -> HTTP %{http_code}\n' ${INGRESS}/"
note "404 from the ingress controller's default backend: the Ingress objects"
note "are gone, so the controller has no rule for these host names."

step "What is deliberately still running"
run "k get nodes"
run "k get ns cse644 -o custom-columns='NAMESPACE:.metadata.name,STATUS:.status.phase' 2>/dev/null || echo 'assignment 02 namespace not present on this cluster'"
run "k -n cse644 get deploy 2>/dev/null || true"
run "k get pods -n ingress-nginx -n metallb-system 2>/dev/null | head -5"
note "Assignment 02's workloads, the ingress controller, MetalLB and the"
note "cluster itself are untouched. This script removes what it created and"
note "nothing else."

finish
