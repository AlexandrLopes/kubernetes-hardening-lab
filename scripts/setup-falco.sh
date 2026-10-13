#!/usr/bin/env bash
#
# Installs Falco with the lab rules. Admission control decides what is allowed to
# start; Falco watches what the containers do once they are running.
# Safe to re-run.
#
# Usage: bash scripts/setup-falco.sh

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require helm kubectl

step "Falco (chart ${FALCO_CHART_VERSION})"
helm repo add falcosecurity https://falcosecurity.github.io/charts >/dev/null 2>&1 || true
helm repo update falcosecurity >/dev/null
helm upgrade --install falco falcosecurity/falco \
  --version "${FALCO_CHART_VERSION}" \
  --namespace falco --create-namespace \
  --values "${REPO_ROOT}/manifests/falco/values.yaml" \
  --wait --timeout 10m >/dev/null
info "installed"

kube -n falco rollout status daemonset/falco --timeout=300s >/dev/null
info "running on the worker node"

step "Rules"
loaded="$(kube -n falco logs daemonset/falco -c falco --tail=200 2>/dev/null \
  | grep -c "Loading rules from" || true)"
info "rule files loaded: ${loaded:-0}"

printf '\nAlerts: kubectl -n falco logs -f daemonset/falco -c falco\n'
printf 'Next: bash scripts/simulate-incident.sh\n'
