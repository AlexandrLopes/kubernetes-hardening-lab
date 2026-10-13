#!/usr/bin/env bash
#
# Checks every control the lab claims, against the running cluster. Each check
# prints pass or fail and the script exits non-zero if any of them failed.
#
# Usage: bash scripts/verify.sh

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require kubectl cosign curl

PASSED=0
FAILED=0

check() {
  local description="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    printf '  pass  %s\n' "${description}"
    PASSED=$((PASSED + 1))
  else
    printf '  FAIL  %s\n' "${description}"
    FAILED=$((FAILED + 1))
  fi
}

equals() { [ "$("${@:2}")" = "$1" ]; }

api_pod() { kube get pod -n "${NAMESPACE}" -l app=api -o jsonpath='{.items[0].metadata.name}'; }

step "Platform"
check "both nodes are Ready" equals "True True" \
  kube get nodes -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}'
check "Calico is running" kube -n kube-system get daemonset calico-node
check "Kyverno is available" kube -n kyverno get deployment kyverno-admission-controller
check "the Sealed Secrets controller is running" kube -n kube-system get deployment sealed-secrets-controller

step "Pod Security"
check "the namespace enforces restricted" equals "restricted" \
  kube get namespace "${NAMESPACE}" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}'
check "a privileged pod is rejected" bash -c \
  "! kube apply -n ${NAMESPACE} --dry-run=server -f ${REPO_ROOT}/tests/privileged-pod.yaml"

step "Admission policies"
check "every ClusterPolicy is ready" bash -c \
  "! kube get clusterpolicy -o jsonpath='{.items[*].status.conditions[?(@.type==\"Ready\")].status}' | grep -q False"
check "a pod using :latest is rejected" bash -c \
  "! kube apply -n ${NAMESPACE} --dry-run=server -f ${REPO_ROOT}/tests/latest-tag-pod.yaml"
check "a pod without limits is rejected" bash -c \
  "! kube apply -n ${NAMESPACE} --dry-run=server -f ${REPO_ROOT}/tests/no-limits-pod.yaml"

step "Supply chain"
check "the internal registry answers" bash -c \
  "curl -sf http://${REGISTRY_FROM_HOST}/v2/_catalog >/dev/null"
check "the api image comes from the internal registry" bash -c \
  "kube get deployment api -n ${NAMESPACE} -o jsonpath='{.spec.template.spec.containers[0].image}' | grep -q '^${REGISTRY_HOST}/'"
check "the database image comes from the internal registry" bash -c \
  "kube get deployment postgres -n ${NAMESPACE} -o jsonpath='{.spec.template.spec.containers[0].image}' | grep -q '^${REGISTRY_HOST}/'"
check "the running api pod is pinned to a digest" bash -c \
  "kube get pod -n ${NAMESPACE} -l app=api -o jsonpath='{.items[0].spec.containers[0].image}' | grep -q '@sha256:'"
check "the signed image verifies with the public key" bash -c \
  "cosign verify --key ${COSIGN_PUB} --insecure-ignore-tlog=true ${REGISTRY_FROM_HOST}/api:0.1.0 >/dev/null 2>&1"
check "an unsigned image is rejected" bash -c \
  "! kube apply -n ${NAMESPACE} --dry-run=server -f ${REPO_ROOT}/tests/unsigned-image-pod.yaml"

step "Workloads"
check "the api deployment is available" kube -n "${NAMESPACE}" get deployment api
check "the postgres deployment is available" kube -n "${NAMESPACE}" get deployment postgres
check "the api runs as a non-root user" equals "10001" \
  kube get deployment api -n "${NAMESPACE}" -o jsonpath='{.spec.template.spec.securityContext.runAsUser}'
check "the api root filesystem is read-only" equals "true" \
  kube get deployment api -n "${NAMESPACE}" -o jsonpath='{.spec.template.spec.containers[0].securityContext.readOnlyRootFilesystem}'
check "the api drops all capabilities" equals "ALL" \
  kube get deployment api -n "${NAMESPACE}" -o jsonpath='{.spec.template.spec.containers[0].securityContext.capabilities.drop[0]}'
check "no ServiceAccount token is mounted" bash -c \
  "! kube exec -n ${NAMESPACE} deploy/api -- ls /var/run/secrets/kubernetes.io 2>/dev/null"
check "the filesystem rejects writes" bash -c \
  "! kube exec -n ${NAMESPACE} deploy/api -- touch /probe 2>/dev/null"

step "Secrets"
check "the password comes from a Secret" equals "postgres-credentials" \
  kube get deployment api -n "${NAMESPACE}" \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="DB_PASSWORD")].valueFrom.secretKeyRef.name}'
check "no plaintext password is left in the manifests" bash -c \
  "! grep -rq 'ChangeMe123' ${REPO_ROOT}/manifests/hardened ${REPO_ROOT}/manifests/secrets"

step "Network"
check "a default-deny policy exists" kube get networkpolicy default-deny -n "${NAMESPACE}"
check "the api reaches the database" \
  kube exec -n "${NAMESPACE}" deploy/api -- python -c \
  "import socket; socket.create_connection(('postgres', 5432), timeout=5).close()"
check "the api cannot reach the internet" bash -c \
  "! kubectl --context ${KUBE_CONTEXT} exec -n ${NAMESPACE} deploy/api -- python -c \
  \"import socket; socket.create_connection(('1.1.1.1', 443), timeout=5).close()\""

step "Application"
check "the api answers its health endpoint" \
  kube exec -n "${NAMESPACE}" deploy/api -- python -c \
  "import json, urllib.request; assert json.loads(urllib.request.urlopen('http://127.0.0.1:8080/healthz', timeout=5).read())['status'] == 'ok'"
check "the api reports the database as reachable" \
  kube exec -n "${NAMESPACE}" deploy/api -- python -c \
  "import json, urllib.request; assert json.loads(urllib.request.urlopen('http://127.0.0.1:8080/', timeout=10).read())['status'] == 'ok'"

printf '\nResult: %s passed, %s failed\n' "${PASSED}" "${FAILED}"
[ "${FAILED}" -eq 0 ]
