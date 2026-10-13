#!/usr/bin/env bash
#
# Reproduces the two moves an attacker makes after reaching a pod, and shows what
# Falco saw. Nothing here is destructive: it opens a shell, tries to read the
# ServiceAccount token, and prints the matching alerts.
#
# Usage: bash scripts/simulate-incident.sh

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require kubectl

kube -n falco get daemonset falco >/dev/null 2>&1 || fail "Falco is not installed; run scripts/setup-falco.sh"

step "Step 1 — a shell inside the application container"
since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
kube exec -n "${NAMESPACE}" deploy/api -- sh -c 'id' >/dev/null 2>&1 || true
info "executed"

step "Step 2 — reading the ServiceAccount token"
kube exec -n "${NAMESPACE}" deploy/api -- sh -c \
  'cat /var/run/secrets/kubernetes.io/serviceaccount/token' >/dev/null 2>&1 || true
info "attempted in the api pod: there is no token there, so there is nothing to read"

# To show the rule itself works, a pod that does mount a token is created, read
# once, and removed.
kube apply -n "${NAMESPACE}" -f "${REPO_ROOT}/tests/token-canary-pod.yaml" >/dev/null
kube -n "${NAMESPACE}" wait --for=condition=ready pod/token-canary --timeout=120s >/dev/null
kube exec -n "${NAMESPACE}" token-canary -- \
  cat /var/run/secrets/kubernetes.io/serviceaccount/token >/dev/null 2>&1 || true
kube -n "${NAMESPACE}" delete pod token-canary --ignore-not-found >/dev/null
info "read once in a pod that does mount one, then removed"

step "What Falco saw"
sleep 10
alerts="$(kube -n falco logs daemonset/falco -c falco --since-time="${since}" 2>/dev/null \
  | grep -o '"rule":"[^"]*"' | sort | uniq -c || true)"
if [ -n "${alerts}" ]; then
  printf '%s\n' "${alerts}" | sed 's/^/   /'
else
  info "no alert yet; Falco can take a few seconds (watch: kubectl -n falco logs -f daemonset/falco -c falco)"
fi

step "What stopped the attack before Falco even mattered"
info "the container runs as uid 10001 with a read-only filesystem"
info "no ServiceAccount token is mounted, so there is nothing to steal"
info "the default-deny NetworkPolicy leaves nowhere to move laterally"
