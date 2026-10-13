#!/usr/bin/env bash
#
# Installs Argo CD and hands it the cluster: from here on, Git is the desired
# state and the cluster is corrected to match it. The script ends by proving
# self-heal, deleting the default-deny NetworkPolicy and waiting for Argo CD to
# put it back. Safe to re-run.
#
# Usage: bash scripts/setup-gitops.sh

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require kubectl

step "Argo CD (${ARGOCD_VERSION})"
if kube -n argocd get deployment argocd-server >/dev/null 2>&1; then
  info "already installed"
else
  kube create namespace argocd --dry-run=client -o yaml | kube apply -f - >/dev/null
  kube -n argocd apply --server-side -f \
    "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml" >/dev/null
fi
kube -n argocd wait --for=condition=available deployment --all --timeout=300s >/dev/null
info "ready"

step "Project and application"
kube apply -f "${REPO_ROOT}/manifests/gitops/" >/dev/null
info "applied"

step "First synchronisation"
status=""
for _ in $(seq 1 90); do
  status="$(kube -n argocd get application hardening-lab \
    -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null || true)"
  [ "${status}" = "Synced/Healthy" ] && break
  sleep 2
done
[ "${status}" = "Synced/Healthy" ] || fail "the application is ${status:-unknown}; check: kubectl -n argocd describe application hardening-lab"
info "hardening-lab: ${status}"

step "Self-heal"
# Drift is introduced on purpose. Argo CD compares the cluster with Git and puts
# the control back without anyone running kubectl.
kube -n "${NAMESPACE}" delete networkpolicy default-deny >/dev/null
restored=false
for _ in $(seq 1 120); do
  if kube -n "${NAMESPACE}" get networkpolicy default-deny >/dev/null 2>&1; then
    restored=true
    break
  fi
  sleep 1
done
if [ "${restored}" = true ]; then
  info "the deleted NetworkPolicy was restored from Git"
else
  kube apply -f "${REPO_ROOT}/manifests/network-policies/00-default-deny.yaml" >/dev/null
  fail "Argo CD did not restore the policy within 120s (it was restored by hand)"
fi

printf '\nUI: kubectl -n argocd port-forward svc/argocd-server 8081:443, then https://localhost:8081 (user admin).\n'
printf 'Password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d\n'
