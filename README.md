# Kubernetes Hardening Lab

[![CI](https://github.com/AlexandrLopes/kubernetes-hardening-lab/actions/workflows/ci.yml/badge.svg)](https://github.com/AlexandrLopes/kubernetes-hardening-lab/actions/workflows/ci.yml)

A two-tier application (a Python API and a PostgreSQL database) deployed twice on
a local Kind cluster: first deliberately insecure, then hardened and kept that
way by the cluster itself. Everything runs on the local machine, is reproducible
with the scripts below, and every control is proven by a verification script that
fails when a control is removed.

The application is not the point. What surrounds it is: an admission layer that
refuses an insecure pod, a network where nothing reaches anything by default, a
database password that is encrypted in Git, and a way to prove all of it on a
running cluster.

## What is here

| Area | Where |
|------|-------|
| Insecure baseline (the "before") | [`manifests/base/`](manifests/base) |
| Internal registry and image signing | [`scripts/setup-registry.sh`](scripts/setup-registry.sh), [`scripts/sign-image.sh`](scripts/sign-image.sh) |
| Hardened workloads | [`manifests/hardened/`](manifests/hardened) |
| Admission policies | [`manifests/kyverno-policies/`](manifests/kyverno-policies) |
| Network segmentation | [`manifests/network-policies/`](manifests/network-policies) |
| Encrypted database password | [`manifests/secrets/`](manifests/secrets), [`scripts/seal-secrets.sh`](scripts/seal-secrets.sh) |
| Pods that must be rejected | [`tests/`](tests) |
| Decisions and trade-offs | [`docs/decisions.md`](docs/decisions.md) |

## Baseline and hardened, side by side

| | Baseline | Hardened |
|---|---|---|
| Container user | root, `privileged: true` | uid 10001, no privilege escalation |
| Root filesystem | writable | read-only, with explicit volumes for what must be written |
| Capabilities | all | `drop: ["ALL"]` |
| Seccomp | none | `RuntimeDefault` (added by a Kyverno mutation when missing) |
| Image | `:latest`, from the local cache | internal registry only, cosign-signed, tag rewritten to the verified digest |
| Database password | hardcoded in the manifest | SealedSecret, decrypted only inside the cluster |
| API access | ServiceAccount token mounted by default | no token, no permissions |
| Resources | unbounded | requests and limits on every container |
| Network | every pod reaches every pod | default-deny, with three explicit paths |
| Image provenance | nothing checks where the image came from | admission refuses an unsigned image, and any registry but the internal one |

## Requirements

| Tool | Verified version |
|------|------------------|
| Docker | 29.8.0 (Docker Desktop) |
| Kind | v0.33.0 |
| kubectl | v1.36.1 |
| kubeseal | v0.40.0 |
| cosign | v3.1.3 |
| crane | 0.22.1 |
| Trivy | 0.74.0 |
| gitleaks | 8.30.1 |
| shellcheck | 0.11.0 |

The cluster itself runs Kubernetes v1.37.0, with Calico v3.27.0, Kyverno v1.19.1
and Sealed Secrets v0.40.0.

## Step-by-step execution

Run every command from the repository root.

### Step 1 — Provision the environment

```bash
bash scripts/setup-cluster.sh
```

Creates the Kind cluster `hardening-lab` (one control-plane, one worker, default
CNI disabled), installs Calico, Kyverno and the Sealed Secrets controller, starts
the internal registry and teaches the cluster to use it, builds the application
image into the nodes, and deploys the deliberately insecure API and database into
the `shop` namespace.

Expected: `baseline deployed to the shop namespace`, and `kubectl get pods -n shop`
shows both insecure pods running.

### Step 2 — Publish and sign the images

```bash
bash scripts/sign-image.sh
```

Builds the application image and pushes it to the internal registry, copies the
database image there by digest, and signs both with cosign. The private key stays
on the machine and is git-ignored; `cosign.pub` is committed, because the cluster
needs it to verify. An extra unsigned tag is pushed on purpose, so the policy can
be shown rejecting something.

Expected: `signed and verified api@sha256:...` and the same for postgres.

### Step 3 — Apply the hardening

```bash
bash scripts/harden.sh
```

Removes the baseline, delivers the public key to Kyverno, labels the namespace with the `restricted` Pod Security
Standard in `enforce` mode, applies the Kyverno policies and the NetworkPolicies,
generates the database password as a SealedSecret, and deploys the hardened
workloads.

Expected: `7 policies ready`, `5 policies applied`,
`Secret created by the controller`, and both deployments rolled out.

### Step 4 — Verify every control

```bash
bash scripts/verify.sh
```

Twenty-nine checks against the running cluster: platform, Pod Security, admission
policies, supply chain, workload hardening, secrets, network segmentation and the
application itself.

Expected: `Result: 29 passed, 0 failed`.

The checks are not decorative. Deleting the NetworkPolicy that lets the API reach
the database turns `the api reaches the database` into a failure, and restoring
the policy turns it back.

### Step 5 — Watch the controls refuse a pod

```bash
kubectl apply -n shop --dry-run=server -f tests/privileged-pod.yaml
kubectl apply -n shop --dry-run=server -f tests/latest-tag-pod.yaml
kubectl apply -n shop --dry-run=server -f tests/no-limits-pod.yaml
kubectl apply -n shop --dry-run=server -f tests/unsigned-image-pod.yaml
```

Each manifest violates one rule. `--dry-run=server` creates nothing, and the
cluster still evaluates it, so the error names the layer that refused the pod:
Pod Security Admission for the first, Kyverno for the rest. The last one is the
interesting case: the image exists in the internal registry and breaks no other
rule, but nothing signed it.

### Step 6 — Run the CI gates locally

```bash
bash scripts/ci.sh
```

The same four gates the workflow runs, with no cluster required: shellcheck,
gitleaks over the full history, Trivy on the manifests and Trivy on the
application image.

Expected: `All gates passed.`

### Teardown

```bash
bash scripts/teardown.sh
```

## Solution by control

| Control | Implementation | Verified by |
|---------|----------------|-------------|
| Pod hardening | `manifests/hardened/`: non-root, `drop: ALL`, seccomp `RuntimeDefault`, read-only root filesystem, no privilege escalation, no mounted token, requests and limits | `verify.sh`; Trivy config gate |
| Admission control | `restricted` Pod Security in `enforce` mode, plus 5 validating Kyverno policies and 1 mutating policy (default seccomp) | rejection tests in `verify.sh` and `tests/` |
| Network segmentation | `manifests/network-policies/`: default-deny, DNS, `api -> postgres:5432`, node to `api:8080` for probes | connectivity tests in `verify.sh` |
| Secrets | password generated locally and committed only as a SealedSecret; plaintext never touches disk or Git | `verify.sh`; gitleaks over the full history |
| Supply chain | internal registry as the only allowed source, cosign signature required at admission, tag rewritten to the verified digest, base image pinned by digest, Trivy gate on CRITICAL findings | `verify.sh`, `ci.sh`, GitHub Actions |
| CI | shellcheck, gitleaks, Trivy on manifests and image, with the tools pinned and checksum-verified | the CI badge above |

## Repository layout

```
app/                        the API and its Dockerfile
kind/                       cluster definition (two nodes, default CNI disabled)
manifests/base/             insecure baseline (reference only, never a template)
manifests/hardened/         namespace, service accounts, database and API
manifests/kyverno-policies/, network-policies/, secrets/
scripts/                    every step above
cosign.pub                  the public key the cluster verifies against
tests/                      pods that must be rejected
docs/decisions.md           decision log
```

## Notes

The signing key pair is created on first run. `cosign.key` never leaves the
machine and is git-ignored; `cosign.pub` is committed, so running the lab on
another machine produces a new pair and a new `cosign.pub`.

The internal registry speaks plain HTTP, which is why the lab configures
containerd on each node, adds a CoreDNS entry so pods resolve the registry by the
same name, and allows Kyverno to read an insecure registry. In a real cluster the
registry would have TLS and none of that would be needed.

## Repository security

No plaintext secrets: the database password exists only as a SealedSecret, which
is ciphertext that the in-cluster controller alone can read. `.env` files, private
keys and kubeconfigs are git-ignored. gitleaks scans the full history on every
push, with a single documented exception for the SealedSecret path, checked
against a deliberate test file to confirm the scanner still catches a real key.
The CI workflow pins the checkout action by commit SHA and verifies the SHA-256
of gitleaks and Trivy before running them.
