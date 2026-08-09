#!/usr/bin/env bash
# Evidence 06: a change made through Git, reconciled into the cluster.
#
# Three commits, because the first one teaches something the other two cannot.
#
#   Commit 1  edits only the ConfigMap. Argo CD syncs it and reports the
#             application Synced and Healthy - and the running application does
#             not change at all. The cluster matches Git; the behaviour does
#             not. This is the most common way a GitOps deployment silently
#             does nothing.
#   Commit 2  bumps the Pod template annotation, which changes the Pod
#             template, which is what actually rolls the Deployment.
#   Commit 3  moves the api workload to a new image version - a change to the
#             application itself rather than to its configuration.
#
# Usage: bash scripts/06_git_driven_change.sh [new-api-tag]
set -uo pipefail
source "$(dirname "$0")/lib.sh"

NEW_API_TAG="${1:-1.1.0}"
CM_FILE="${ROOT}/k8s/10-web-configmap.yaml"
DEPLOY_FILE="${ROOT}/k8s/11-web-deployment.yaml"
API_FILE="${ROOT}/k8s/23-api-deployment.yaml"

start_log "06-git-driven-change"

CUR_REV=$(grep -oE 'cse644\.dev/config-revision: "[0-9]+"' "$DEPLOY_FILE" | grep -oE '[0-9]+')
NEW_REV=$((CUR_REV + 1))
NEW_MESSAGE="Customized Nginx, reconciled from Git by Argo CD (config revision ${NEW_REV})."

step "Before: what is running now"
run "ing ${WEB_HOST} ${INGRESS}/message"
run "kn get pods -l app.kubernetes.io/name=web -o custom-columns='POD:.metadata.name,AGE:.metadata.creationTimestamp,REV:.metadata.annotations.cse644\\.dev/config-revision'"
run "kn get configmap web-config -o jsonpath='{.data.APP_MESSAGE}'; echo"
run "argo app get cse644-platform --refresh -o json | python3 -c \"import json,sys; a=json.load(sys.stdin)['status']; print('sync:', a['sync']['status'], a['sync']['revision'][:8], '| health:', a['health']['status'])\""

# ---------------------------------------------------------------------------
step "COMMIT 1 - change only the ConfigMap"
# ---------------------------------------------------------------------------
run "sed -i 's|^  APP_MESSAGE: .*|  APP_MESSAGE: \"${NEW_MESSAGE}\"|' '${CM_FILE}'"
run "git -C '$ROOT' diff --stat"
run "git -C '$ROOT' diff -- k8s/10-web-configmap.yaml"
commit_push "Change the web message through the ConfigMap only" "k8s/10-web-configmap.yaml"

stamp "waiting for Argo CD to observe ${HEAD_SHA:0:8}"
run "argo app get cse644-platform --refresh >/dev/null"
wait_revision cse644-platform "$HEAD_SHA" 90
stamp "observed"
wait_app cse644-platform Synced Healthy 90

step "Argo CD says Synced and Healthy"
run "argo app get cse644-platform -o json | python3 -c \"import json,sys; a=json.load(sys.stdin)['status']; print('sync:', a['sync']['status'], a['sync']['revision'][:8], '| health:', a['health']['status'])\""
run "kn get configmap web-config -o jsonpath='{.data.APP_MESSAGE}'; echo '   <- the cluster does match Git'"

step "And the application has not changed"
run "ing ${WEB_HOST} ${INGRESS}/message"
run "kn get pods -l app.kubernetes.io/name=web -o custom-columns='POD:.metadata.name,START:.status.startTime'"
note "Same Pods, same start times, same page. envFrom reads a ConfigMap once,"
note "at container start. Argo CD updated the object it was asked to update and"
note "correctly reports success - it has no way to know that this particular"
note "object is only read at boot. Nothing here is broken; the manifest simply"
note "did not ask for a restart."

# ---------------------------------------------------------------------------
step "COMMIT 2 - bump the Pod template annotation"
# ---------------------------------------------------------------------------
note "Changing anything inside spec.template changes the Pod template hash,"
note "which creates a new ReplicaSet, which rolls the fleet. The annotation"
note "carries no meaning to Kubernetes; its only job is to be different."
run "sed -i 's|cse644.dev/config-revision: \"${CUR_REV}\"|cse644.dev/config-revision: \"${NEW_REV}\"|' '${DEPLOY_FILE}'"
run "git -C '$ROOT' diff -- k8s/11-web-deployment.yaml"
commit_push "Roll the web Deployment so it picks up config revision ${NEW_REV}" "k8s/11-web-deployment.yaml"

stamp "waiting for Argo CD to observe ${HEAD_SHA:0:8}"
wait_revision cse644-platform "$HEAD_SHA" 90
stamp "observed - watching the rollout"
run "kn rollout status deploy/web --timeout=180s"
wait_app cse644-platform Synced Healthy 120

step "Now the application has changed"
run "ing ${WEB_HOST} ${INGRESS}/message"
run "kn get pods -l app.kubernetes.io/name=web -o custom-columns='POD:.metadata.name,START:.status.startTime,REV:.metadata.annotations.cse644\\.dev/config-revision'"
run "kn get rs -l app.kubernetes.io/name=web -o custom-columns='REPLICASET:.metadata.name,DESIRED:.spec.replicas,CURRENT:.status.replicas'"
note "maxUnavailable: 0 means the old replicas kept serving until the new ones"
note "were ready. No request was dropped to change a public message."

# ---------------------------------------------------------------------------
step "COMMIT 3 - move the api workload to a new image version"
# ---------------------------------------------------------------------------
CUR_API_TAG=$(grep -oE "${API_IMAGE_REPO}:[0-9.]+" "$API_FILE" | head -1 | cut -d: -f2)
if [ "$CUR_API_TAG" = "$NEW_API_TAG" ]; then
    note "already at ${NEW_API_TAG}; skipping the image bump"
else
    run "ing ${API_HOST} ${INGRESS}/metrics | grep -e '^cse644_api_build_info' -e '^cse644_api_notes_bytes' || true"
    run "sed -i 's|${API_IMAGE_REPO}:${CUR_API_TAG}|${API_IMAGE_REPO}:${NEW_API_TAG}|' '${API_FILE}'"
    run "git -C '$ROOT' diff -- k8s/23-api-deployment.yaml"
    commit_push "Deploy api ${NEW_API_TAG}" "k8s/23-api-deployment.yaml apps/api/app.py"

    stamp "waiting for Argo CD to observe ${HEAD_SHA:0:8}"
    wait_revision cse644-platform "$HEAD_SHA" 90
    stamp "observed - watching the rollout"
    run "kn rollout status deploy/api --timeout=240s"
    wait_app cse644-platform Synced Healthy 120

    step "The new version is live, and it brought a new metric with it"
    run "ing ${API_HOST} ${INGRESS}/api/info | python3 -c \"import json,sys; d=json.load(sys.stdin); print('version:', d['version'], '| pod:', d['pod'])\""
    run "ing ${API_HOST} -D - -o /dev/null ${INGRESS}/ | grep -i x-app-version"
    run "ing ${API_HOST} ${INGRESS}/metrics | grep -e '^cse644_api_build_info' -e '^cse644_api_notes_bytes'"
    note "The image tag in Git, the OCI label on the image, and the value the"
    note "process reports all say ${NEW_API_TAG}. APP_VERSION is baked in at build"
    note "time and never set in a manifest, so those three cannot drift apart."

    step "The volume outlived the Pod"
    run "ing ${API_HOST} ${INGRESS}/api/notes"
    note "Notes written by the previous version's Pod, read by the new one."
fi

step "Argo CD's own history of what it deployed"
run "argo app history cse644-platform"

finish
