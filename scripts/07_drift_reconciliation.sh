#!/usr/bin/env bash
# Evidence 07: what the controller does when the live cluster stops matching Git.
#
# "Detected" and "corrected" are two different behaviours and they are two
# different settings. Running the same drift twice - once with selfHeal off,
# once with it on - is the only way to show which one is doing the work.
#
# The selfHeal setting is changed through Git, not with `argocd app set`. It
# has to be: the platform Application is itself managed by the root
# Application, so a CLI change to it would be drift, and would be reverted
# within seconds. The GitOps loop applies to the GitOps configuration too, and
# this script depends on that.
set -uo pipefail
source "$(dirname "$0")/lib.sh"

APP_FILE="${ROOT}/gitops/apps/10-platform.yaml"

start_log "07-drift-reconciliation"

step "Starting state"
run "kn get deploy web -o custom-columns='DEPLOY:.metadata.name,REPLICAS:.spec.replicas,READY:.status.readyReplicas'"
run "kn get configmap web-config -o jsonpath='{.data.APP_MESSAGE}'; echo"
run "argo app get cse644-platform --refresh -o json | python3 -c \"import json,sys; a=json.load(sys.stdin)['status']; print('sync:', a['sync']['status'], '| health:', a['health']['status'])\""

# ===========================================================================
step "PART 1 - turn selfHeal off, through Git"
# ===========================================================================
note "Not with 'argocd app set'. gitops/apps/10-platform.yaml is synced by the"
note "root Application, so a CLI edit to this Application would itself be drift"
note "and would be reverted. Changing the file is the only durable way."
run "sed -n '/^  syncPolicy:/,/^  revisionHistoryLimit/p' '${APP_FILE}'"
run "sed -i '0,/      selfHeal: true/s//      selfHeal: false/' '${APP_FILE}'"
run "git -C '$ROOT' diff -- gitops/apps/10-platform.yaml"
commit_push "Disable selfHeal on the platform Application to demonstrate drift detection" "gitops/apps/10-platform.yaml"
wait_revision cse644-root "$HEAD_SHA" 90
run "kargo get application cse644-platform -o jsonpath='{.spec.syncPolicy.automated}'; echo"

# ===========================================================================
step "PART 2 - change the live cluster directly, behind Git's back"
# ===========================================================================
note "Two changes an operator might plausibly make in a hurry: scale down, and"
note "edit a message. Both objects are declared in Git, so both are now wrong."
stamp "introducing drift"
run "kn scale deployment/web --replicas=1"
run "kn patch configmap web-config --type merge -p '{\"data\":{\"APP_MESSAGE\":\"edited directly on the cluster with kubectl\"}}'"
sleep 8

step "Argo CD detects it"
run "argo app get cse644-platform --refresh -o json | python3 -c \"import json,sys; a=json.load(sys.stdin)['status']; print('sync:', a['sync']['status'], '| health:', a['health']['status'])\""
run "argo app get cse644-platform | sed -n '/GROUP/,\$p'"

step "And says exactly what differs"
note "argocd app diff prints desired-versus-live per object. Left is Git."
run "argo app diff cse644-platform || true"

step "The difference persists - detection alone changes nothing"
for i in 1 2 3 4 5 6; do
    stamp "replicas=$(kn get deploy web -o jsonpath='{.spec.replicas}')  sync=$(kargo get application cse644-platform -o jsonpath='{.status.sync.status}')"
    sleep 10
done
run "kn get deploy web -o custom-columns='DEPLOY:.metadata.name,REPLICAS:.spec.replicas,READY:.status.readyReplicas'"
note "A minute of the cluster being wrong, reported accurately and left alone."
note "That is the correct behaviour for selfHeal: false - Argo CD is telling"
note "the truth and waiting for a human to decide."

# ===========================================================================
step "PART 3 - reconcile on demand"
# ===========================================================================
stamp "operator runs a manual sync"
run "argo app sync cse644-platform --prune | tail -30"
run "kn get deploy web -o custom-columns='DEPLOY:.metadata.name,REPLICAS:.spec.replicas,READY:.status.readyReplicas'"
run "kn get configmap web-config -o jsonpath='{.data.APP_MESSAGE}'; echo '   <- back to the value in Git'"

# ===========================================================================
step "PART 4 - turn selfHeal back on, through Git"
# ===========================================================================
run "sed -i '0,/      selfHeal: false/s//      selfHeal: true/' '${APP_FILE}'"
run "git -C '$ROOT' diff -- gitops/apps/10-platform.yaml"
commit_push "Re-enable selfHeal on the platform Application" "gitops/apps/10-platform.yaml"
wait_revision cse644-root "$HEAD_SHA" 90
run "kargo get application cse644-platform -o jsonpath='{.spec.syncPolicy.automated}'; echo"

# ===========================================================================
step "PART 5 - the same drift, with selfHeal on"
# ===========================================================================
stamp "introducing the same drift again"
kn scale deployment/web --replicas=1 >/dev/null
echo "\$ kubectl -n ${NS} scale deployment/web --replicas=1"
START=$(date +%s)
for i in $(seq 1 60); do
    R=$(kn get deploy web -o jsonpath='{.spec.replicas}')
    stamp "spec.replicas=${R}"
    [ "$R" = "3" ] && break
    sleep 2
done
END=$(date +%s)
note "Reverted after $((END - START)) seconds, with nobody watching."
run "kn get deploy web -o custom-columns='DEPLOY:.metadata.name,REPLICAS:.spec.replicas,READY:.status.readyReplicas'"
run "kargo get application cse644-platform -o jsonpath='{.status.sync.status}'; echo"

# ===========================================================================
step "PART 6 - delete a managed object outright"
# ===========================================================================
note "The strongest form of drift: the object is gone, not merely different."
stamp "deleting the entire web Deployment"
run "kn delete deployment web"
run "kn get deploy 2>&1 | head -5"
START=$(date +%s)
for i in $(seq 1 90); do
    if kn get deploy web >/dev/null 2>&1; then break; fi
    sleep 2
done
END=$(date +%s)
stamp "the Deployment came back after $((END - START)) seconds"
run "kn rollout status deploy/web --timeout=180s"
run "kn get deploy,pod -l app.kubernetes.io/name=web"
run "ing ${WEB_HOST} ${INGRESS}/message"
note "Nobody re-applied anything. The desired state never changed; only the"
note "cluster did, and the controller put it back."

step "Final state"
wait_app cse644-platform Synced Healthy 120
run "argo app get cse644-platform -o json | python3 -c \"import json,sys; a=json.load(sys.stdin)['status']; print('sync:', a['sync']['status'], a['sync']['revision'][:8], '| health:', a['health']['status'])\""

finish
