#!/usr/bin/env bash
# Shared helpers for the CSE644 Assignment 03 demonstration scripts.
#
# Every script prints the exact command before running it, so the transcripts
# under evidence/ can be replayed line by line. Nothing here hides output and
# nothing here prints a credential.

# kubectl, kind and argocd are installed per-user (no root needed on this
# machine).
export PATH="$HOME/.local/bin:$PATH"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EVIDENCE="$ROOT/evidence"
mkdir -p "$EVIDENCE"

CLUSTER="cse644"
CTX="kind-${CLUSTER}"

NS="cse644-gitops"          # the application
MON_NS="cse644-monitoring"  # Prometheus and Grafana
ARGO_NS="argocd"            # the GitOps controller

REPO_URL="https://github.com/0luioiul0/cse644-gitops.git"
REPO_WEB="https://github.com/0luioiul0/cse644-gitops"
BRANCH="main"

# Pinned versions. Nothing in this repository tracks a floating tag.
ARGOCD_VERSION="v3.5.0"
WEB_IMAGE_REPO="luioiul/cse644-gitops-web"
API_IMAGE_REPO="luioiul/cse644-gitops-api"
IMAGE_TAG="1.0.0"

# Host-side entry point fixed by Assignment 02's kind/cluster.yaml: host port
# 8090 is mapped to port 80 of the control-plane node, where ingress-nginx
# listens. Everything below is routed off the Host header alone.
INGRESS="http://localhost:8090"
WEB_HOST="web.gitops.local"
API_HOST="api.gitops.local"
ARGO_HOST="argocd.gitops.local"
GRAFANA_HOST="grafana.gitops.local"
PROM_HOST="prometheus.gitops.local"

k()     { kubectl --context "$CTX" "$@"; }
kn()    { kubectl --context "$CTX" -n "$NS" "$@"; }
kmon()  { kubectl --context "$CTX" -n "$MON_NS" "$@"; }
kargo() { kubectl --context "$CTX" -n "$ARGO_NS" "$@"; }

# The Argo CD CLI in --core mode talks to the Kubernetes API directly with the
# kubeconfig already in use. No argocd-server login, no session token, no
# password anywhere in these transcripts.
#
# Core mode reads its namespace from the kubeconfig context, and it needs to
# find argocd-cm - so it needs a context whose namespace is `argocd`. Rather
# than change the namespace on the context everything else uses, the install
# script adds a second context pointing at the same cluster with that
# namespace set. `kubectl config current-context` is left alone.
ARGO_KUBE_CONTEXT="argocd-core"
argo() { argocd --core --kube-context "$ARGO_KUBE_CONTEXT" "$@"; }

# Request through the ingress controller by Host header.
ing() {
    local host="$1"; shift
    curl -s -H "Host: ${host}" "$@"
}

start_log() {
    local name="$1"
    exec > >(tee "$EVIDENCE/${name}.txt") 2>&1
    echo "==============================================================="
    echo " CSE644 Assignment 03 - ${name}"
    echo " date       : $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo " cluster    : kind/${CLUSTER}   (kubectl context ${CTX})"
    echo " repository : ${REPO_WEB}"
    echo " revision   : $(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    echo "==============================================================="
}

step() {
    echo
    echo "---------------------------------------------------------------"
    echo "STEP: $*"
    echo "---------------------------------------------------------------"
}

note() {
    echo
    echo "  # $*"
}

run() {
    echo
    echo "\$ $*"
    eval "$*"
    local rc=$?
    [ $rc -ne 0 ] && echo "[exit status: $rc]"
    return 0
}

# For commands whose failure IS the evidence.
run_expect_fail() {
    echo
    echo "\$ $*"
    if eval "$*"; then
        echo "[UNEXPECTED: command succeeded]"
    else
        echo "[exit status: $? - failure expected here, this is the evidence]"
    fi
    return 0
}

# A timestamped line, for the demonstrations where "how long did it take" is
# the point.
stamp() {
    echo "[$(date -u '+%H:%M:%S')] $*"
}

wait_http() {
    local url="$1" tries="${2:-60}" hosthdr="${3:-}"
    local args=(-fs -o /dev/null --max-time 4)
    [ -n "$hosthdr" ] && args+=(-H "Host: $hosthdr")
    for _ in $(seq "$tries"); do
        curl "${args[@]}" "$url" 2>/dev/null && return 0
        sleep 1
    done
    echo "[warning: $url did not become ready]"
    return 1
}

# Wait until an Argo CD Application reports the given sync and health state.
# Returns non-zero on timeout rather than hanging a transcript forever.
wait_app() {
    local app="$1" sync="$2" health="$3" tries="${4:-90}"
    for _ in $(seq "$tries"); do
        local s h
        s=$(kargo get application "$app" -o jsonpath='{.status.sync.status}' 2>/dev/null)
        h=$(kargo get application "$app" -o jsonpath='{.status.health.status}' 2>/dev/null)
        if [ "$s" = "$sync" ] && { [ -z "$health" ] || [ "$h" = "$health" ]; }; then
            return 0
        fi
        sleep 2
    done
    echo "[warning: ${app} did not reach ${sync}/${health} in time]"
    return 1
}

# Wait until Argo CD has observed a specific commit for an Application. This is
# what makes "the change arrived through Git" provable rather than assumed.
wait_revision() {
    local app="$1" sha="$2" tries="${3:-90}"
    for _ in $(seq "$tries"); do
        local got
        got=$(kargo get application "$app" -o jsonpath='{.status.sync.revision}' 2>/dev/null)
        [ "${got:0:8}" = "${sha:0:8}" ] && return 0
        sleep 2
    done
    echo "[warning: ${app} did not report revision ${sha:0:8} in time]"
    return 1
}

# How the commit reaches origin.
#
#   direct     this shell runs `git push` itself. The normal case.
#   external   this shell commits, and something outside it pushes. Needed on
#              a machine where the shell running these scripts cannot
#              authenticate to GitHub - this one is a WSL2 distro with Windows
#              interop unregistered, so the clone's credential helper, which
#              shells out to the Windows GitHub CLI, cannot execute at all.
#
# Either way the commit counts as delivered only once origin really has it,
# which is checked below rather than assumed.
PUSH_MODE="${PUSH_MODE:-direct}"

# Wait until origin's branch head actually equals the given commit.
# Read-only, so it needs no credential on a public repository.
wait_remote() {
    local sha="$1" tries="${2:-90}"
    for _ in $(seq "$tries"); do
        [ "$(git -C "$ROOT" ls-remote origin "$BRANCH" 2>/dev/null | cut -f1)" = "$sha" ] && return 0
        sleep 2
    done
    return 1
}

# Commit and get it to origin. The credential helper lives in this clone's
# .git/config and is never printed; nothing about it reaches these transcripts.
#
# `git push` exiting 0 is not proof that origin has the commit, and a push that
# failed must never be reported as a change that reached the cluster: Argo CD
# pulls from origin, so every later assertion in the transcript - "the new
# version is live", "the rollout completed" - would be describing a commit the
# controller cannot see. So this verifies, and aborts the script if the commit
# did not land. An earlier run of this repository produced exactly that
# transcript: three failed pushes, and pages of confident output about a
# deployment that never happened.
commit_push() {
    local message="$1"; shift
    run "git -C '$ROOT' add $*"
    run "git -C '$ROOT' commit -m '$message'"
    HEAD_SHA=$(git -C "$ROOT" rev-parse HEAD)

    if [ "$PUSH_MODE" = "direct" ]; then
        run "git -C '$ROOT' push origin $BRANCH"
    else
        note "PUSH_MODE=${PUSH_MODE}: this shell cannot authenticate to GitHub,"
        note "so the commit is delivered to origin by tooling outside it."
    fi

    if wait_remote "$HEAD_SHA"; then
        note "origin/${BRANCH} is now ${HEAD_SHA:0:8} - the controller can fetch it"
    else
        echo
        echo "[FATAL] ${HEAD_SHA:0:8} never reached origin/${BRANCH}."
        echo "        Everything after this point would describe a change that"
        echo "        Argo CD cannot see. Stopping here rather than writing a"
        echo "        transcript that claims otherwise."
        finish
        exit 1
    fi
}

finish() {
    echo
    echo "==============================================================="
    echo " done: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo "==============================================================="
}
