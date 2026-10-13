#!/usr/bin/env bash
#
# Starts the internal registry and makes the cluster able to use it:
#   - a registry container on the Kind network, reachable as registry.internal
#   - per-node containerd configuration, since the registry speaks plain HTTP
#   - a CoreDNS entry, so pods (Kyverno, when it checks signatures) resolve the
#     same name the nodes use
#   - Kyverno allowed to talk to an insecure registry
# Safe to re-run.
#
# Usage: bash scripts/setup-registry.sh

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require docker kubectl jq

step "Registry container"
if [ "$(docker inspect -f '{{.State.Running}}' "${REGISTRY_CONTAINER}" 2>/dev/null)" = "true" ]; then
  info "${REGISTRY_CONTAINER} is already running"
else
  docker rm -f "${REGISTRY_CONTAINER}" >/dev/null 2>&1 || true
  docker run -d --restart=always --name "${REGISTRY_CONTAINER}" \
    -p "${REGISTRY_FROM_HOST}:5000" "${REGISTRY_IMAGE}" >/dev/null
  info "started on ${REGISTRY_FROM_HOST}"
fi

if ! docker inspect -f '{{json .NetworkSettings.Networks}}' "${REGISTRY_CONTAINER}" | grep -q '"kind"'; then
  docker network connect --alias "${REGISTRY_HOST%%:*}" kind "${REGISTRY_CONTAINER}"
fi
REGISTRY_IP="$(docker inspect -f '{{.NetworkSettings.Networks.kind.IPAddress}}' "${REGISTRY_CONTAINER}")"
info "reachable as ${REGISTRY_HOST} (${REGISTRY_IP}) inside the cluster network"

step "containerd on each node"
for node in $(kind get nodes --name "${CLUSTER_NAME}"); do
  docker exec "${node}" mkdir -p "/etc/containerd/certs.d/${REGISTRY_HOST}"
  docker exec -i "${node}" cp /dev/stdin "/etc/containerd/certs.d/${REGISTRY_HOST}/hosts.toml" <<TOML
[host."http://${REGISTRY_HOST}"]
  capabilities = ["pull", "resolve"]
TOML
  info "${node} configured"
done

step "CoreDNS"
# Pods resolve names through CoreDNS, which knows nothing about Docker network
# aliases, so the registry is added as a static host entry.
if ! kube -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}' | grep -q "${REGISTRY_HOST%%:*}"; then
  patched="$(kube -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}' \
    | awk -v ip="${REGISTRY_IP}" -v host="${REGISTRY_HOST%%:*}" '
        { print }
        $1 == "ready" && !inserted {
          print "    hosts {"
          print "        " ip " " host
          print "        fallthrough"
          print "    }"
          inserted = 1
        }')"
  kube -n kube-system create configmap coredns --from-literal=Corefile="${patched}" \
    --dry-run=client -o yaml | kube -n kube-system replace -f - >/dev/null
  kube -n kube-system rollout restart deployment/coredns >/dev/null
  kube -n kube-system rollout status deployment/coredns --timeout=180s >/dev/null
fi
info "${REGISTRY_HOST%%:*} resolves inside the cluster"

step "Kyverno"
# The registry has no TLS, so the admission controller needs permission to
# fetch signatures over plain HTTP.
for deployment in kyverno-admission-controller kyverno-background-controller; do
  current="$(kube -n kyverno get deployment "${deployment}" \
    -o jsonpath='{.spec.template.spec.containers[0].args}')"
  case "${current}" in
    *"--allowInsecureRegistry=true"*) continue ;;
  esac
  # The flag ships as false by default, so the value is replaced rather than
  # appended: a duplicated flag would be ignored.
  args="$(kube -n kyverno get deployment "${deployment}" -o json \
    | jq -c '[.spec.template.spec.containers[0].args[]
              | sub("^--allowInsecureRegistry=false$"; "--allowInsecureRegistry=true")]
             | if any(startswith("--allowInsecureRegistry")) then . else . + ["--allowInsecureRegistry=true"] end')"
  kube -n kyverno patch deployment "${deployment}" --type=json \
    -p "[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/args\",\"value\":${args}}]" >/dev/null
  kube -n kyverno rollout status "deployment/${deployment}" --timeout=180s >/dev/null
done
info "kyverno can read the internal registry"
