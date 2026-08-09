#!/usr/bin/env bash
# Evidence 02: the repository and its revision history.
#
# In a GitOps system the repository is not documentation about the deployment -
# it is the deployment. So "what is in the repository" and "what commits it has
# had" are cluster-state evidence, not paperwork.
set -uo pipefail
source "$(dirname "$0")/lib.sh"

start_log "02-repository"

step "Remote and branch"
run "git -C '$ROOT' remote -v"
run "git -C '$ROOT' branch --show-current"
run "git -C '$ROOT' status --short --branch"

step "Revision history"
run "git -C '$ROOT' log --oneline --decorate --graph -30"

step "What the repository holds"
run "git -C '$ROOT' ls-files | sed 's|/[^/]*$||' | sort | uniq -c | sort -rn"
run "git -C '$ROOT' ls-files"

step "The four things the assignment asks the repository to contain"
run "ls -1 ${ROOT}/apps/web ${ROOT}/apps/api          # application source and container build"
run "ls -1 ${ROOT}/k8s                                # Kubernetes configuration"
run "ls -1 ${ROOT}/gitops/apps ${ROOT}/gitops/bootstrap  # GitOps configuration"
run "ls -1 ${ROOT}/monitoring                         # monitoring configuration"

step "No credential is committed"
note "A search of every tracked file for the patterns that would matter."
run "git -C '$ROOT' grep -nEI '(BEGIN [A-Z ]*PRIVATE KEY|dckr_pat_|gh[pousr]_[A-Za-z0-9]{16,}|AKIA[0-9A-Z]{16})' -- . || echo 'no matches - clean'"
note "The only Secret manifest in the repository is a template with a"
note "placeholder, and it is the file .gitignore explicitly allows through."
run "grep -n 'REPLACE_ME' ${ROOT}/k8s/21-api-secret.example.yaml"
run "cat ${ROOT}/.gitignore"

step "What Argo CD is actually reading"
run "argo app get cse644-platform -o json | python3 -c \"import json,sys; a=json.load(sys.stdin)['spec']['source']; print(a['repoURL'], 'path', a['path'], 'branch', a['targetRevision'])\""
run "kargo get application cse644-root cse644-platform cse644-monitoring -o custom-columns='APP:.metadata.name,PATH:.spec.source.path,REVISION:.status.sync.revision,SYNC:.status.sync.status,HEALTH:.status.health.status'"

finish
