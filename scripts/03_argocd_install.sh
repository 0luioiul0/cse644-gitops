#!/usr/bin/env bash
# Evidence 03: install the GitOps controller.
#
# Argo CD rather than Flux. Both reconcile a Git repository into a cluster and
# either would satisfy the assignment; the deciding factor was that Argo CD
# ships a server that renders the live-versus-desired diff, the sync status and
# the health of every managed object as one view. Three of this assignment's
# required demonstrations are about exactly that difference - a change arriving,
# drift being detected, a deployment being unhealthy - and being able to show
# them as a diff rather than describe them is worth a component.
#
# Argo CD is installed from its upstream release manifest, pinned. It is not
# managed by itself: a controller that reconciles its own installation cannot
# recover from a bad commit to that installation.
set -uo pipefail
source "$(dirname "$0")/lib.sh"

start_log "03-argocd-install"

step "Install the Argo CD CLI (per-user, no root)"
if command -v argocd >/dev/null 2>&1 && [[ "$(argocd version --client --short 2>/dev/null)" == *"${ARGOCD_VERSION}"* ]]; then
    note "argocd ${ARGOCD_VERSION} already present"
else
    mkdir -p "$HOME/.local/bin"
    run "curl -sSL -o \$HOME/.local/bin/argocd https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_VERSION}/argocd-linux-amd64"
    run "chmod +x \$HOME/.local/bin/argocd"
fi
run "argocd version --client --short"

step "Create the argocd namespace and apply the pinned upstream install manifest"
run "k create namespace ${ARGO_NS} --dry-run=client -o yaml | k apply -f -"
note "--server-side is required, not a preference. A client-side apply records"
note "the whole submitted object in a last-applied-configuration annotation, and"
note "annotations are capped at 262144 bytes; the applicationsets.argoproj.io CRD"
note "carries a schema larger than that, so a plain apply fails on that one object"
note "with 'metadata.annotations: Too long'. Server-side apply keeps field"
note "ownership in managedFields instead of an annotation and has no such limit."
run "k apply -n ${ARGO_NS} --server-side --force-conflicts -f https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

step "Wait for the control plane to come up"
run "k -n ${ARGO_NS} rollout status deploy/argocd-server --timeout=300s"
run "k -n ${ARGO_NS} rollout status deploy/argocd-repo-server --timeout=300s"
run "k -n ${ARGO_NS} rollout status statefulset/argocd-application-controller --timeout=300s"
run "kargo get pods -o wide"

step "Serve the UI over plain HTTP behind the ingress controller"
note "argocd-server terminates TLS itself by default and redirects HTTP to"
note "HTTPS. Behind an ingress that also handles TLS the result is a redirect"
note "loop. server.insecure=true hands TLS termination to the ingress - which"
note "on this local cluster means plain HTTP on localhost, a limitation of the"
note "environment that is recorded in the README rather than hidden."
run "kargo patch configmap argocd-cmd-params-cm --type merge -p '{\"data\":{\"server.insecure\":\"true\"}}'"

step "Read-only anonymous access to the UI"
note "So the dashboard and application tree can be screenshotted and reviewed"
note "without a password existing anywhere in this repository or in these"
note "transcripts. The default role is readonly: an anonymous visitor can look"
note "at everything and change nothing. This is acceptable because the cluster"
note "listens on localhost only; it would not be on a reachable network."
run "kargo patch configmap argocd-cm --type merge -p '{\"data\":{\"users.anonymous.enabled\":\"true\"}}'"
run "kargo patch configmap argocd-rbac-cm --type merge -p '{\"data\":{\"policy.default\":\"role:readonly\"}}'"
run "kargo rollout restart deploy/argocd-server"
run "k -n ${ARGO_NS} rollout status deploy/argocd-server --timeout=300s"

step "Expose it on the shared ingress controller"
run "k apply -f ${ROOT}/gitops/bootstrap/01-argocd-ingress.yaml"
run "kargo get ingress"
wait_http "${INGRESS}/" 60 "${ARGO_HOST}"
run "ing ${ARGO_HOST} -o /dev/null -w 'GET http://${ARGO_HOST}:8090/ -> HTTP %{http_code}\n' ${INGRESS}/"

step "The CLI talks to the Kubernetes API directly"
note "--core means the CLI uses the kubeconfig rather than logging in to"
note "argocd-server, so no session token and no password appear in any of"
note "these transcripts. Core mode takes its namespace from the kube context,"
note "and needs to find argocd-cm - hence a second context pointing at the same"
note "cluster with the namespace set. The current context is not changed."
run "kubectl config set-context ${ARGO_KUBE_CONTEXT} --cluster=${CTX} --user=${CTX} --namespace=${ARGO_NS}"
run "kubectl config get-contexts"
run "argo version --short"
run "argo app list"

step "The initial admin Secret still exists and is left alone"
note "kubectl describe prints a Secret's key names and byte counts, never its"
note "values. The admin password is not read, decoded or used anywhere in this"
note "repository - --core mode means nothing needs it."
run "kargo describe secret argocd-initial-admin-secret | tail -8"

finish
