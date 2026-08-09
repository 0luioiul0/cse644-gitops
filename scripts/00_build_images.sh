#!/usr/bin/env bash
# Build both application images and push them to Docker Hub.
#
# Assignment 02 built images locally and side-loaded them into the cluster with
# `kind load docker-image`, because they existed in no registry. That cannot
# work for GitOps. Argo CD's job is to make the cluster match Git; if the image
# a manifest names only exists in one machine's Docker daemon, then the cluster
# state depends on something Git has no knowledge of, and a rebuild of the
# cluster from the repository alone would fail. So these images go to a public
# registry and the manifests reference them by immutable-ish pinned tag.
#
# Usage:
#   bash scripts/00_build_images.sh              # builds and pushes 1.0.0
#   bash scripts/00_build_images.sh 1.1.0        # builds and pushes 1.1.0
#
# Requires `docker login` to have been done already. No credential is read,
# printed or stored by this script.
set -uo pipefail
source "$(dirname "$0")/lib.sh"

TAG="${1:-$IMAGE_TAG}"

start_log "00-image-build-and-push"

step "Docker engine and registry identity"
run "docker version --format 'client {{.Client.Version}} / server {{.Server.Version}}'"
# Prints the account name only. The credential itself lives in the Docker
# config and is never read by this script.
run "docker system info --format '{{.Username}}' | sed 's/^/logged in to Docker Hub as: /'"

step "Build ${WEB_IMAGE_REPO}:${TAG}"
run "docker build --build-arg APP_VERSION=${TAG} -t ${WEB_IMAGE_REPO}:${TAG} ${ROOT}/apps/web"

step "Build ${API_IMAGE_REPO}:${TAG}"
run "docker build --build-arg APP_VERSION=${TAG} -t ${API_IMAGE_REPO}:${TAG} ${ROOT}/apps/api"

step "The version is baked in, not configured"
note "The manifests never set APP_VERSION. It comes from the image, so what"
note "the running application reports cannot disagree with what was deployed."
run "docker run --rm ${API_IMAGE_REPO}:${TAG} python -c \"import os; print('APP_VERSION in image =', os.environ['APP_VERSION'])\""
run "docker image inspect ${WEB_IMAGE_REPO}:${TAG} --format '{{index .Config.Labels \"org.opencontainers.image.version\"}}' | sed 's/^/web image label: /'"

step "Push to Docker Hub"
run "docker push ${WEB_IMAGE_REPO}:${TAG}"
run "docker push ${API_IMAGE_REPO}:${TAG}"

step "Confirm the tags resolve from the registry, not from the local daemon"
run "docker manifest inspect docker.io/${WEB_IMAGE_REPO}:${TAG} | head -20"
run "docker manifest inspect docker.io/${API_IMAGE_REPO}:${TAG} | head -20"

finish
