#!/usr/bin/env bash
#
# Installs Argo CD and hands it the cluster: from here on, Git is the desired
# state and the cluster is corrected to match it. The script ends by proving
# self-heal, deleting the default-deny NetworkPolicy and waiting for Argo CD to
# put it back. Safe to re-run.
#
# Usage: bash scripts/setup-gitops.sh

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require kubectl jq

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
# A sync that is still running would swallow the drift test below, so wait until
# the application has finished its operation before touching anything.
for _ in $(seq 1 60); do
  phase="$(kube -n argocd get application hardening-lab -o jsonpath='{.status.operationState.phase}' 2>/dev/null || true)"
  [ -z "${phase}" ] || [ "${phase}" != "Running" ] && break
  sleep 2
done
info "hardening-lab: ${status}"

step "Self-heal"
# Argo CD waits longer between successive corrections (2s, 6s, 18s and up), and
# the counter survives across runs, so a repeated test would look like a failure.
# A manual sync starts a fresh operation and resets it.
revision="$(kube -n argocd get application hardening-lab -o jsonpath='{.status.sync.revision}')"
previous="$(kube -n argocd get application hardening-lab -o jsonpath='{.status.operationState.startedAt}')"
kube -n argocd patch application hardening-lab --type merge \
  -p "$(jq -cn --arg rev "${revision}" \
    '{operation: {initiatedBy: {username: "setup-gitops"}, sync: {revision: $rev, prune: true}}}')" >/dev/null
fresh=""
for _ in $(seq 1 90); do
  fresh="$(kube -n argocd get application hardening-lab -o json | jq -r --arg previous "${previous}" '
    select(.operation == null) | .status.operationState
    | select(.startedAt != $previous and .phase == "Succeeded"
             and .operation.initiatedBy.username == "setup-gitops")
    | "\(.operation.sync.autoHealAttemptsCount // 0)"')"
  [ -n "${fresh}" ] && break
  sleep 2
done
[ "${fresh}" = "0" ] || fail "the manual sync did not complete (got '${fresh}')"
info "manual sync done; the self-heal counter is back to zero"

# Drift is introduced on purpose. Argo CD compares the cluster with Git and puts
# the control back without anyone running kubectl.
started="$(date +%s)"
kube -n "${NAMESPACE}" delete networkpolicy default-deny >/dev/null
restored=false
for _ in $(seq 1 60); do
  if kube -n "${NAMESPACE}" get networkpolicy default-deny >/dev/null 2>&1; then
    restored=true
    seconds=$(( $(date +%s) - started ))
    break
  fi
  sleep 1
done
if [ "${restored}" = true ]; then
  info "the deleted NetworkPolicy was restored from Git in ${seconds}s"
else
  kube apply -f "${REPO_ROOT}/manifests/network-policies/00-default-deny.yaml" >/dev/null
  fail "Argo CD did not restore the policy within 60s (it was restored by hand)"
fi

printf '\nUI: kubectl -n argocd port-forward svc/argocd-server 8081:443, then https://localhost:8081 (user admin).\n'
printf 'Password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d\n'
