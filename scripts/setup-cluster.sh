#!/usr/bin/env bash
#
# Creates the Kind cluster, installs the platform components and deploys the
# deliberately insecure baseline. Safe to re-run: an existing cluster is reused.
#
# Usage: bash scripts/setup-cluster.sh

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require docker kind kubectl

step "Cluster"
if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  info "cluster ${CLUSTER_NAME} already exists"
else
  kind create cluster --config "${REPO_ROOT}/kind/cluster.yaml"
fi

step "CNI (Calico ${CALICO_VERSION})"
kube apply -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml"
kube -n kube-system rollout status daemonset/calico-node --timeout=300s
kube wait --for=condition=ready nodes --all --timeout=300s
info "nodes ready"

step "Admission controller (Kyverno ${KYVERNO_VERSION})"
kube apply -f "https://github.com/kyverno/kyverno/releases/download/${KYVERNO_VERSION}/install.yaml" --server-side
kube -n kyverno wait --for=condition=available deployment --all --timeout=300s
info "kyverno ready"

step "Sealed Secrets (${SEALED_SECRETS_VERSION})"
kube apply -f "https://github.com/bitnami-labs/sealed-secrets/releases/download/${SEALED_SECRETS_VERSION}/controller.yaml"
kube -n kube-system rollout status deployment/sealed-secrets-controller --timeout=300s
info "controller ready"

step "Application image"
bash "${REPO_ROOT}/scripts/build-image.sh"

step "Insecure baseline"
kube create namespace "${NAMESPACE}" --dry-run=client -o yaml | kube apply -f -
kube apply -f "${REPO_ROOT}/manifests/base/api.yaml" -f "${REPO_ROOT}/manifests/base/postgres.yaml"
info "baseline deployed to the ${NAMESPACE} namespace"

printf '\nNext: bash scripts/harden.sh\n'
