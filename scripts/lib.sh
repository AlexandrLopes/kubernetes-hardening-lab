# shellcheck shell=bash
# Shared helpers. Sourced by the other scripts, never executed on its own.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER_NAME="hardening-lab"
KUBE_CONTEXT="kind-${CLUSTER_NAME}"
NAMESPACE="shop"
REGISTRY_CONTAINER="hardening-lab-registry"
REGISTRY_IMAGE="registry:2.8.3@sha256:a3d8aaa63ed8681a604f1dea0aa03f100d5895b6a58ace528858a7b332415373"
# The registry answers on this name inside the Kind network, and on the second
# one from the host, where images are pushed.
REGISTRY_HOST="registry.internal:5000"
REGISTRY_FROM_HOST="127.0.0.1:5001"
APP_IMAGE="${REGISTRY_HOST}/api:0.1.0"
APP_IMAGE_LOCAL="hardening-lab/api:0.1.0"
POSTGRES_IMAGE="${REGISTRY_HOST}/postgres:16-alpine"
POSTGRES_UPSTREAM="postgres:16-alpine@sha256:721873c34ceb9f8d8fc265984940dc982404c105f19ad51be9fdc5970a6080ea"
COSIGN_KEY="${REPO_ROOT}/cosign.key"
COSIGN_PUB="${REPO_ROOT}/cosign.pub"
CALICO_VERSION="v3.27.0"
KYVERNO_VERSION="v1.19.1"
SEALED_SECRETS_VERSION="v0.40.0"
ARGOCD_VERSION="v3.5.5"
FALCO_CHART_VERSION="9.2.0"

step() { printf '\n== %s\n' "$1"; }
info() { printf '   %s\n' "$1"; }
fail() { printf '   error: %s\n' "$1" >&2; exit 1; }

require() {
  local tool
  for tool in "$@"; do
    command -v "${tool}" >/dev/null 2>&1 || fail "${tool} is not installed"
  done
}

kube() { kubectl --context "${KUBE_CONTEXT}" "$@"; }
# Exported so the checks that run inside "bash -c" see it too: without this they
# would fail for the wrong reason, and a negated check would pass for it.
export -f kube

export REPO_ROOT CLUSTER_NAME KUBE_CONTEXT NAMESPACE APP_IMAGE APP_IMAGE_LOCAL \
  POSTGRES_IMAGE POSTGRES_UPSTREAM REGISTRY_CONTAINER REGISTRY_IMAGE REGISTRY_HOST \
  REGISTRY_FROM_HOST COSIGN_KEY COSIGN_PUB \
  CALICO_VERSION KYVERNO_VERSION SEALED_SECRETS_VERSION ARGOCD_VERSION FALCO_CHART_VERSION
