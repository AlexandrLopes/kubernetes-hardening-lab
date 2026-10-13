# shellcheck shell=bash
# Shared helpers. Sourced by the other scripts, never executed on its own.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER_NAME="hardening-lab"
KUBE_CONTEXT="kind-${CLUSTER_NAME}"
NAMESPACE="shop"
APP_IMAGE="hardening-lab/api:0.1.0"
CALICO_VERSION="v3.27.0"
KYVERNO_VERSION="v1.19.1"
SEALED_SECRETS_VERSION="v0.40.0"

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

export REPO_ROOT CLUSTER_NAME KUBE_CONTEXT NAMESPACE APP_IMAGE \
  CALICO_VERSION KYVERNO_VERSION SEALED_SECRETS_VERSION
