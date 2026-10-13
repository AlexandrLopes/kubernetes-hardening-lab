#!/usr/bin/env bash
#
# Publishes the images the cluster is allowed to run: the application image is
# built here, the database image is copied from upstream by digest, and both are
# signed with cosign. An extra unsigned tag is pushed on purpose, so the
# signature policy can be shown rejecting something.
#
# The signing key stays local and is git-ignored; only the public key is
# committed, because that is what the cluster needs to verify.
#
# Usage: bash scripts/sign-image.sh

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require docker crane cosign

export COSIGN_PASSWORD="${COSIGN_PASSWORD:-}"

step "Signing key"
if [ -f "${COSIGN_KEY}" ]; then
  info "using the existing key pair"
else
  (cd "${REPO_ROOT}" && cosign generate-key-pair >/dev/null)
  info "generated cosign.key (local only) and cosign.pub (committed)"
fi

step "Application image"
docker build --quiet --tag "${APP_IMAGE_LOCAL}" "${REPO_ROOT}/app" >/dev/null
docker tag "${APP_IMAGE_LOCAL}" "${REGISTRY_FROM_HOST}/api:0.1.0"
docker push --quiet "${REGISTRY_FROM_HOST}/api:0.1.0" >/dev/null
APP_DIGEST="$(crane digest "${REGISTRY_FROM_HOST}/api:0.1.0")"
info "pushed ${APP_IMAGE} (${APP_DIGEST})"

step "Database image"
crane copy "${POSTGRES_UPSTREAM}" "${REGISTRY_FROM_HOST}/postgres:16-alpine" 2>/dev/null
POSTGRES_DIGEST="$(crane digest "${REGISTRY_FROM_HOST}/postgres:16-alpine")"
info "copied ${POSTGRES_IMAGE} (${POSTGRES_DIGEST})"

step "Signatures"
for reference in "${REGISTRY_FROM_HOST}/api@${APP_DIGEST}" "${REGISTRY_FROM_HOST}/postgres@${POSTGRES_DIGEST}"; do
  # Keep the classic signature format and stay off the public transparency log:
  # this registry is internal and the lab must run without reaching sigstore.
  cosign sign --yes --key "${COSIGN_KEY}" \
    --tlog-upload=false --use-signing-config=false --new-bundle-format=false \
    "${reference}" >/dev/null 2>&1
  cosign verify --key "${COSIGN_PUB}" --insecure-ignore-tlog=true "${reference}" >/dev/null 2>&1 \
    || fail "signature verification failed for ${reference}"
  info "signed and verified ${reference##*/}"
done

step "Unsigned image, for the rejection test"
# A signature belongs to a digest, not to a tag, so this image is built with an
# extra label: a different digest, which nothing signed.
docker build --quiet --label lab.unsigned=true --tag "${REGISTRY_FROM_HOST}/api:unsigned" \
  "${REPO_ROOT}/app" >/dev/null
docker push --quiet "${REGISTRY_FROM_HOST}/api:unsigned" >/dev/null
info "pushed api:unsigned ($(crane digest "${REGISTRY_FROM_HOST}/api:unsigned")) without a signature, on purpose"
