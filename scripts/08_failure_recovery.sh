#!/usr/bin/env bash
# Evidence 08: break the deployment through Git, diagnose it, fix it through Git.
#
# The failure is a tag that does not exist in the registry - a typo in an image
# reference. It is the most common way a GitOps deployment breaks, and it is
# the one where the controller is least able to help: the manifest is valid,
# the sync succeeds, and the application still goes down.
#
# One commit breaks both workloads. They do not both fail:
#
#   web  RollingUpdate with maxUnavailable: 0. The new ReplicaSet cannot
#        produce a ready Pod, so no old Pod is removed. Three replicas keep
#        serving the previous image for as long as the bad commit stays in Git.
#   api  Recreate, because its ReadWriteOnce volume can only be mounted once.
#        The old Pod is terminated before the new one is created, so by the
#        time the kubelet discovers the image does not exist there is nothing
#        left serving. This is a real outage.
#
# Same commit, same registry error, opposite outcomes - decided entirely by a
# rollout strategy that was chosen for a storage constraint.
set -uo pipefail
source "$(dirname "$0")/lib.sh"

BAD_TAG="1.9.9-tag-that-does-not-exist"
WEB_FILE="${ROOT}/k8s/11-web-deployment.yaml"
API_FILE="${ROOT}/k8s/23-api-deployment.yaml"

start_log "08-failure-recovery"

step "Before: everything healthy"
run "argo app get cse644-platform --refresh -o json | python3 -c \"import json,sys; a=json.load(sys.stdin)['status']; print('sync:', a['sync']['status'], '| health:', a['health']['status'])\""
run "kn get deploy,pod -o wide"
run "ing ${WEB_HOST} -o /dev/null -w 'web  -> HTTP %{http_code}\n' ${INGRESS}/"
run "ing ${API_HOST} -o /dev/null -w 'api  -> HTTP %{http_code}\n' ${INGRESS}/api/info"
run "ing ${API_HOST} ${INGRESS}/api/notes"

# ===========================================================================
step "INTRODUCE THE FAILURE - one commit, both workloads"
# ===========================================================================
CUR_WEB_TAG=$(grep -oE "${WEB_IMAGE_REPO}:[0-9a-z.-]+" "$WEB_FILE" | head -1 | cut -d: -f2)
CUR_API_TAG=$(grep -oE "${API_IMAGE_REPO}:[0-9a-z.-]+" "$API_FILE" | head -1 | cut -d: -f2)
note "current tags: web ${CUR_WEB_TAG}, api ${CUR_API_TAG}"
run "sed -i 's|${WEB_IMAGE_REPO}:${CUR_WEB_TAG}|${WEB_IMAGE_REPO}:${BAD_TAG}|' '${WEB_FILE}'"
run "sed -i 's|${API_IMAGE_REPO}:${CUR_API_TAG}|${API_IMAGE_REPO}:${BAD_TAG}|' '${API_FILE}'"
run "git -C '$ROOT' diff --unified=1 -- k8s/11-web-deployment.yaml k8s/23-api-deployment.yaml"
commit_push "BREAK: bump both images to a tag that was never pushed" "k8s/11-web-deployment.yaml k8s/23-api-deployment.yaml"
BAD_SHA="$HEAD_SHA"

stamp "waiting for Argo CD to observe ${BAD_SHA:0:8}"
run "argo app get cse644-platform --refresh >/dev/null"
wait_revision cse644-platform "$BAD_SHA" 90
stamp "observed"

# ===========================================================================
step "DIAGNOSIS 1 - the sync succeeded. That is not the same as working."
# ===========================================================================
sleep 20
run "argo app get cse644-platform -o json | python3 -c \"import json,sys; a=json.load(sys.stdin)['status']; print('sync  :', a['sync']['status'], a['sync']['revision'][:8]); print('health:', a['health']['status'])\""
note "Synced means 'the cluster matches Git'. Git asked for an image that does"
note "not exist, and the cluster now faithfully asks for an image that does not"
note "exist. Sync status is about agreement, health status is about whether the"
note "result works. Alerting on sync status alone would have missed this."

step "DIAGNOSIS 2 - what Kubernetes says"
run "kn get pods -o wide"
run "kn get rs -o custom-columns='REPLICASET:.metadata.name,IMAGE:.spec.template.spec.containers[0].image,DESIRED:.spec.replicas,READY:.status.readyReplicas'"
run "kn get events --sort-by=.lastTimestamp | grep -i -e pull -e fail | tail -12"
BAD_POD=$(kn get pods -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.containerStatuses[0].state.waiting.reason}{"\n"}{end}' 2>/dev/null | grep -E 'ImagePullBackOff|ErrImagePull' | head -1 | cut -d' ' -f1)
run "kn describe pod ${BAD_POD} | sed -n '/Events:/,\$p'"
note "The registry answered, and its answer was 'not found': containerd could"
note "not resolve the reference. Not a network failure and not a credential"
note "failure, either of which would say so - the tag was simply never pushed."

step "DIAGNOSIS 3 - who is actually down"
run "ing ${WEB_HOST} -o /dev/null -w 'web  -> HTTP %{http_code}\n' ${INGRESS}/"
run "ing ${API_HOST} -o /dev/null -w 'api  -> HTTP %{http_code}\n' ${INGRESS}/api/info"
run "ing ${WEB_HOST} ${INGRESS}/version"
note "web answers, from the previous image. maxUnavailable: 0 refused to"
note "remove a working replica for one that never became ready."
note "The 503 comes from the ingress controller, not from the application -"
note "there is no application left to answer. An EndpointSlice is how the"
note "controller learns where it may send a request, and readiness is what"
note "gates each address in it:"
run "kn get endpointslice -l kubernetes.io/service-name=api-clusterip -o custom-columns='SLICE:.metadata.name,ADDRESSES:.endpoints[*].addresses,READY:.endpoints[*].conditions.ready'"
run "kn get endpointslice -l kubernetes.io/service-name=web-clusterip -o custom-columns='SLICE:.metadata.name,ADDRESSES:.endpoints[*].addresses,READY:.endpoints[*].conditions.ready'"
note "web keeps three ready addresses and carries the stuck new Pod as a"
note "fourth, not-ready one; the controller simply skips that address. api has"
note "a single address and it is not ready, so there is nothing routable left."
note "That is the whole difference: RollingUpdate added a broken Pod alongside"
note "working ones, Recreate deleted the working Pod before discovering the"
note "replacement could not start."

step "DIAGNOSIS 4 - the Deployment gives up"
note "progressDeadlineSeconds is 180 in these manifests rather than the 600s"
note "default, so a stuck rollout is reported within a demonstration's"
note "timescale. Waiting for the condition to flip:"
for i in $(seq 1 24); do
    C=$(kn get deploy api -o jsonpath='{.status.conditions[?(@.type=="Progressing")].reason}')
    stamp "api Progressing reason = ${C:-<none>}"
    [ "$C" = "ProgressDeadlineExceeded" ] && break
    sleep 10
done
run "kn get deploy -o custom-columns='DEPLOY:.metadata.name,READY:.status.readyReplicas,AVAILABLE:.status.availableReplicas,PROGRESSING:.status.conditions[?(@.type==\"Progressing\")].reason'"
run "argo app get cse644-platform --refresh -o json | python3 -c \"import json,sys; a=json.load(sys.stdin)['status']; print('sync  :', a['sync']['status']); print('health:', a['health']['status'])\""
run "argo app resources cse644-platform | grep -i -e deployment -e health || true"

# ===========================================================================
step "RECOVERY - correct the desired state, not the cluster"
# ===========================================================================
note "The tempting fix is 'kubectl set image' - it would work in about two"
note "seconds. It is also the wrong answer: Git would still hold the broken"
note "tag, selfHeal would put it back, and the next person to sync would break"
note "production again. The recovery has to happen where the desired state"
note "lives."
run "git -C '$ROOT' revert --no-edit ${BAD_SHA}"
run "git -C '$ROOT' show --stat HEAD"
deliver_head
GOOD_SHA="$HEAD_SHA"
stamp "the revert is on origin as ${GOOD_SHA:0:8}"

run "argo app get cse644-platform --refresh >/dev/null"
wait_revision cse644-platform "$GOOD_SHA" 120
stamp "Argo CD observed the revert"
run "kn rollout status deploy/api --timeout=300s"
run "kn rollout status deploy/web --timeout=300s"
wait_app cse644-platform Synced Healthy 180

step "After: healthy again, and nothing was applied by hand"
run "argo app get cse644-platform -o json | python3 -c \"import json,sys; a=json.load(sys.stdin)['status']; print('sync  :', a['sync']['status'], a['sync']['revision'][:8]); print('health:', a['health']['status'])\""
run "kn get deploy,pod -o wide"
run "ing ${WEB_HOST} -o /dev/null -w 'web  -> HTTP %{http_code}\n' ${INGRESS}/"
run "ing ${API_HOST} -o /dev/null -w 'api  -> HTTP %{http_code}\n' ${INGRESS}/api/info"
run "ing ${API_HOST} ${INGRESS}/api/info | python3 -c \"import json,sys; d=json.load(sys.stdin); print('version:', d['version'], '| pod:', d['pod'])\""

step "The data survived the outage"
run "ing ${API_HOST} ${INGRESS}/api/notes"
note "The PersistentVolumeClaim was never part of the broken commit, so it was"
note "never deleted. The notes written before the failure are still there."

step "The whole incident, as Git tells it"
run "git -C '$ROOT' log --oneline -4"
note "Two commits: the one that broke it and the one that undid it. The"
note "revert is a new commit rather than a force-push, so the history of the"
note "incident is still readable - which is the point of recovering this way."

finish
