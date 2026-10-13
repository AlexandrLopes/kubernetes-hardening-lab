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
| Image | `:latest`, mutable | pinned tag, base image pinned by digest |
| Database password | hardcoded in the manifest | SealedSecret, decrypted only inside the cluster |
| API access | ServiceAccount token mounted by default | no token, no permissions |
| Resources | unbounded | requests and limits on every container |
| Network | every pod reaches every pod | default-deny, with three explicit paths |

## Requirements

| Tool | Verified version |
|------|------------------|
| Docker | 29.8.0 (Docker Desktop) |
| Kind | v0.33.0 |
| kubectl | v1.36.1 |
| kubeseal | v0.40.0 |
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
CNI disabled), installs Calico, Kyverno and the Sealed Secrets controller, builds
the application image into the nodes, and deploys the deliberately insecure API
and database into the `shop` namespace.

Expected: `baseline deployed to the shop namespace`, and `kubectl get pods -n shop`
shows both insecure pods running.

### Step 2 — Apply the hardening

```bash
bash scripts/harden.sh
```

Removes the baseline, labels the namespace with the `restricted` Pod Security
Standard in `enforce` mode, applies the Kyverno policies and the NetworkPolicies,
generates the database password as a SealedSecret, and deploys the hardened
workloads.

Expected: `5 policies ready`, `5 policies applied`,
`Secret created by the controller`, and both deployments rolled out.

### Step 3 — Verify every control

```bash
bash scripts/verify.sh
```

Twenty-three checks against the running cluster: platform, Pod Security,
admission policies, workload hardening, secrets, network segmentation and the
application itself.

Expected: `Result: 23 passed, 0 failed`.

The checks are not decorative. Deleting the NetworkPolicy that lets the API reach
the database turns `the api reaches the database` into a failure, and restoring
the policy turns it back.

### Step 4 — Watch the controls refuse a pod

```bash
kubectl apply -n shop --dry-run=server -f tests/privileged-pod.yaml
kubectl apply -n shop --dry-run=server -f tests/latest-tag-pod.yaml
kubectl apply -n shop --dry-run=server -f tests/no-limits-pod.yaml
```

Each manifest violates one rule. `--dry-run=server` creates nothing, and the
cluster still evaluates it, so the error names the layer that refused the pod:
Pod Security Admission for the first, Kyverno for the other two.

### Step 5 — Run the CI gates locally

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
| Admission control | `restricted` Pod Security in `enforce` mode, plus 4 validating Kyverno policies and 1 mutating policy (default seccomp) | rejection tests in `verify.sh` and `tests/` |
| Network segmentation | `manifests/network-policies/`: default-deny, DNS, `api -> postgres:5432`, node to `api:8080` for probes | connectivity tests in `verify.sh` |
| Secrets | password generated locally and committed only as a SealedSecret; plaintext never touches disk or Git | `verify.sh`; gitleaks over the full history |
| Supply chain | base image pinned by digest, application image pinned by tag, Trivy gate on CRITICAL findings | `ci.sh`, GitHub Actions |
| CI | shellcheck, gitleaks, Trivy on manifests and image, with the tools pinned and checksum-verified | the CI badge above |

## Repository layout

```
app/                        the API and its Dockerfile
kind/                       cluster definition (two nodes, default CNI disabled)
manifests/base/             insecure baseline (reference only, never a template)
manifests/hardened/         namespace, service accounts, database and API
manifests/kyverno-policies/, network-policies/, secrets/
scripts/                    every step above
tests/                      pods that must be rejected
docs/decisions.md           decision log
```

## Repository security

No plaintext secrets: the database password exists only as a SealedSecret, which
is ciphertext that the in-cluster controller alone can read. `.env` files, private
keys and kubeconfigs are git-ignored. gitleaks scans the full history on every
push, with a single documented exception for the SealedSecret path, checked
against a deliberate test file to confirm the scanner still catches a real key.
The CI workflow pins the checkout action by commit SHA and verifies the SHA-256
of gitleaks and Trivy before running them.

## How this was built

Built with Claude Code as a pair. I set the rules the work had to follow, decided
the scope and reviewed every change; the assistant proposed and implemented
inside those rules. Nothing was accepted on trust: the cluster was built from
scratch, `verify.sh` was run against it, and each check was proven by removing
the control it checks and watching the check fail. The problems found that way,
and how they were fixed, are in [`docs/decisions.md`](docs/decisions.md) and in
the commit history.
