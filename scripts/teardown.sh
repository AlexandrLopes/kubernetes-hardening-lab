#!/usr/bin/env bash
#
# Deletes the cluster. The image stays in the local Docker cache.
#
# Usage: bash scripts/teardown.sh

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require kind

kind delete cluster --name "${CLUSTER_NAME}"
