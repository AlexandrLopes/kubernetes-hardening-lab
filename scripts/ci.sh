#!/usr/bin/env bash
#
# The gates the CI workflow runs. They need no cluster, so this script is the
# same locally and in GitHub Actions:
#   1. shellcheck: every script passes the linter
#   2. gitleaks: no secret anywhere in the git history
#   3. trivy config: no HIGH or CRITICAL misconfiguration in the manifests
#      (the deliberately insecure baseline is excluded)
#   4. trivy image: no CRITICAL vulnerability in the application image
# The first failing gate stops the run.
#
# Usage: bash scripts/ci.sh

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require shellcheck gitleaks trivy docker

cd "${REPO_ROOT}"

step "[1/4] Shell scripts (shellcheck)"
shellcheck -x -P scripts scripts/*.sh
info "clean"

step "[2/4] Secrets in the git history (gitleaks)"
gitleaks detect --no-banner --redact --config .gitleaks.toml
info "no leaks"

step "[3/4] Manifest misconfiguration (trivy config)"
trivy config --quiet --exit-code 1 --severity HIGH,CRITICAL \
  --skip-dirs manifests/base --skip-dirs tests .
info "no HIGH or CRITICAL findings"

step "[4/4] Image vulnerabilities (trivy image)"
docker image inspect "${APP_IMAGE}" >/dev/null 2>&1 || docker build --quiet --tag "${APP_IMAGE}" app >/dev/null
trivy image --quiet --exit-code 1 --severity CRITICAL --ignore-unfixed "${APP_IMAGE}"
info "no CRITICAL vulnerabilities"

printf '\nAll gates passed.\n'
