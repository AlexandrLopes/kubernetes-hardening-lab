#!/usr/bin/env bash
#
# Turns the insecure baseline into the hardened deployment: Pod Security on the
# namespace, Kyverno policies, NetworkPolicies, the sealed database password and
# the hardened workloads. Safe to re-run.
#
# Usage: bash scripts/harden.sh

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require kubectl kubeseal

step "Removing the insecure baseline"
kube delete -f "${REPO_ROOT}/manifests/base/api.yaml" -f "${REPO_ROOT}/manifests/base/postgres.yaml" \
  --ignore-not-found --wait
kube -n "${NAMESPACE}" delete pods --field-selector status.phase=Failed --ignore-not-found >/dev/null
info "baseline removed"

step "Pod Security on the namespace"
kube apply -f "${REPO_ROOT}/manifests/hardened/00-namespace.yaml"
info "enforce=restricted"

step "Signature verification key"
[ -f "${COSIGN_PUB}" ] || fail "cosign.pub is missing; run scripts/sign-image.sh first"
kube -n kyverno create secret generic cosign-public-key \
  --from-file=cosign.pub="${COSIGN_PUB}" --dry-run=client -o yaml | kube apply -f - >/dev/null
info "public key delivered to kyverno"

step "Admission policies"
kube apply -f "${REPO_ROOT}/manifests/kyverno-policies/"
kube wait --for=condition=ready clusterpolicy --all --timeout=120s
info "$(kube get clusterpolicy --no-headers | wc -l | tr -d ' ') policies ready"

step "Network policies"
kube apply -f "${REPO_ROOT}/manifests/network-policies/"
info "$(kube get networkpolicy -n "${NAMESPACE}" --no-headers | wc -l | tr -d ' ') policies applied"

step "Database password (SealedSecret)"
bash "${REPO_ROOT}/scripts/seal-secrets.sh"
kube apply -f "${REPO_ROOT}/manifests/secrets/"
for _ in $(seq 1 30); do
  kube get secret postgres-credentials -n "${NAMESPACE}" >/dev/null 2>&1 && break
  sleep 1
done
kube get secret postgres-credentials -n "${NAMESPACE}" >/dev/null 2>&1 \
  || fail "the controller did not create the Secret from the SealedSecret"
info "Secret created by the controller"

step "Hardened workloads"
kube apply -f "${REPO_ROOT}/manifests/hardened/"
kube -n "${NAMESPACE}" rollout status deployment/postgres --timeout=180s
kube -n "${NAMESPACE}" rollout status deployment/api --timeout=180s
info "api and postgres running"

printf '\nNext: bash scripts/verify.sh\n'
