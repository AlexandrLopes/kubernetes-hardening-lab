#!/usr/bin/env bash
#
# Builds the application image and loads it into the Kind nodes. The baseline
# also references :latest, which is tagged here on purpose so the insecure
# manifest runs and the Kyverno policy has something real to reject later.
#
# Usage: bash scripts/build-image.sh

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require docker kind

docker build --quiet --tag "${APP_IMAGE}" --tag "hardening-lab/api:latest" "${REPO_ROOT}/app" >/dev/null
info "built ${APP_IMAGE}"

kind load docker-image "${APP_IMAGE}" "hardening-lab/api:latest" --name "${CLUSTER_NAME}"
info "loaded into the cluster nodes"
