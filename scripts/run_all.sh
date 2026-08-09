#!/usr/bin/env bash
# Run every demonstration in order and regenerate evidence/.
#
# Roughly 25 minutes end to end. Most of that is not this script working: it is
# waiting for a rollout to fail its progress deadline, and four minutes of
# generated load. Both waits are the evidence.
#
# Not included, because it is destructive and because it needs the images to
# exist first:
#   scripts/00_build_images.sh   builds and pushes to Docker Hub
#   scripts/cleanup.sh           removes everything and verifies it is gone
#
# Prerequisites: a running KinD cluster with ingress-nginx (Assignment 02's
# scripts/01_cluster_up.sh), and a clone of this repository whose `origin` the
# local git can push to - several demonstrations work by committing.
set -uo pipefail
cd "$(dirname "$0")/.."

STAGES=(
    01_cluster_check
    02_repository
    03_argocd_install
    04_bootstrap
    05_app_access
    06_git_driven_change
    07_drift_reconciliation
    08_failure_recovery
    09_observability
    10_grafana
)

START=$(date +%s)
for stage in "${STAGES[@]}"; do
    echo
    echo "###############################################################"
    echo "# scripts/${stage}.sh"
    echo "###############################################################"
    bash "scripts/${stage}.sh" >/dev/null 2>&1 || echo "[stage ${stage} returned $?]"
    echo "  -> evidence/$(ls evidence | grep -E "^${stage:0:2}-" | head -1)"
done

echo
echo "###############################################################"
echo "# scripts/11_screenshots.sh"
echo "###############################################################"
bash scripts/11_screenshots.sh || echo "[screenshots returned $?]"

echo
echo "==============================================================="
echo " all stages finished in $(( ($(date +%s) - START) / 60 )) minutes"
echo "==============================================================="
ls -l evidence
echo
echo "Cleanup, when you are done looking at it:"
echo "  bash scripts/cleanup.sh"
