#!/usr/bin/env bash
# Evidence 01: the Kubernetes environment this assignment runs on.
#
# The cluster is the one built for Assignment 02 by that repository's
# scripts/01_cluster_up.sh - a three-node KinD cluster with ingress-nginx and
# MetalLB. It is reused rather than rebuilt: this assignment is about what runs
# on a cluster, not about creating one again, and reusing it keeps Assignment
# 02's evidence reproducible on the same machine.
set -uo pipefail
source "$(dirname "$0")/lib.sh"

start_log "01-cluster"

step "Client and cluster versions"
run "kubectl version --client=true"
run "kind version"
run "k version -o yaml | sed -n '1,40p'"

step "Nodes"
run "k get nodes -o wide"

step "The control plane answers"
run "k cluster-info"
run "k get --raw /readyz?verbose | tail -20"

step "Shared cluster add-ons (installed for Assignment 02, not by this repository)"
run "k get pods -n ingress-nginx -o wide"
run "k get pods -n metallb-system -o wide"
run "k get ingressclass"
run "k get storageclass"

step "Host entry point"
note "kind/cluster.yaml in the Assignment 02 repository maps host port 8090 to"
note "port 80 of the control-plane node, where the ingress controller listens."
note "Everything in this assignment is reached through that one port, routed"
note "by Host header."
run "docker port ${CLUSTER}-control-plane"

step "What is already on this cluster before Assignment 03 is deployed"
run "k get ns"
run "k get pods -A -o wide | grep -v -e kube-system -e local-path"

finish
