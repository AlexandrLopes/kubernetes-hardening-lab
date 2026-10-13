#!/usr/bin/env bash
#
# Generates the database password and writes it only as a SealedSecret, which is
# safe to commit: it is ciphertext that only this cluster's controller can read.
# The plaintext never touches disk, Git or the process list.
#
# A sealed file is regenerated only when this cluster cannot decrypt it (a new
# cluster has a new key pair) or when --rotate is given.
#
# Usage: bash scripts/seal-secrets.sh [--rotate]

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require kubectl kubeseal openssl

SEALED_FILE="${REPO_ROOT}/manifests/secrets/postgres-credentials-sealed.yaml"
ROTATE=false
[ "${1:-}" = "--rotate" ] && ROTATE=true

if [ "${ROTATE}" = false ] && [ -f "${SEALED_FILE}" ] && kubeseal --validate < "${SEALED_FILE}" >/dev/null 2>&1; then
  info "the existing SealedSecret is readable by this cluster; kept"
  exit 0
fi

mkdir -p "$(dirname "${SEALED_FILE}")"
printf '%s' "$(openssl rand -hex 24)" \
  | kube create secret generic postgres-credentials -n "${NAMESPACE}" \
      --from-file=POSTGRES_PASSWORD=/dev/stdin --dry-run=client -o yaml \
  | kubeseal --format yaml > "${SEALED_FILE}.tmp"
mv "${SEALED_FILE}.tmp" "${SEALED_FILE}"
info "sealed postgres-credentials -> ${SEALED_FILE#"${REPO_ROOT}/"}"
