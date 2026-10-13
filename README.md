# Kubernetes hardening lab

A small two-tier application (a Python API and a PostgreSQL database) deployed
twice on a local Kind cluster: once deliberately insecure, then hardened and kept
that way by the cluster itself.

The point is not the application. The point is everything around it: an
admission layer that refuses an insecure pod, a network where nothing talks to
anything by default, a password that is encrypted in Git, and a script that
proves all of it on a running cluster.

Everything runs locally, in Docker, and tears down in one command.

## The two sides

| | Baseline (`manifests/base/`) | Hardened (`manifests/hardened/`) |
|---|---|---|
| Container user | root, `privileged: true` | uid 10001, no privilege escalation |
| Filesystem | writable | read-only, with explicit volumes for what must be written |
| Capabilities | all of them | `drop: ["ALL"]` |
| Image | `:latest`, mutable | pinned version, base image pinned by digest |
| Database password | hardcoded in the manifest | SealedSecret, decrypted only inside the cluster |
| API token | ServiceAccount token mounted by default | no token, no permissions |
| Resources | unbounded | requests and limits on every container |
| Network | every pod reaches every pod | default-deny, with two explicit paths |

## Controls

- **Pod Security Admission** on the namespace, in `enforce: restricted`.
- **Kyverno policies**: no `:latest`, non-root required, all capabilities
  dropped, resource limits required, and a mutation that adds a default seccomp
  profile instead of rejecting the pod.
- **NetworkPolicies**: deny everything, then allow DNS, the API to the database,
  and the node to the API for readiness probes.
- **Sealed Secrets**: the database password is generated locally, encrypted with
  the cluster's public key and committed as ciphertext. Only the in-cluster
  controller can decrypt it.
- **CI gates**: shellcheck, gitleaks over the full history, Trivy on the
  manifests and Trivy on the application image.

## Running it

Requires Docker, kind, kubectl and kubeseal.

```bash
bash scripts/setup-cluster.sh   # cluster, Calico, Kyverno, Sealed Secrets, insecure baseline
bash scripts/harden.sh          # Pod Security, policies, network, secrets, hardened workloads
bash scripts/verify.sh          # checks every control against the running cluster
bash scripts/teardown.sh        # delete the cluster
```

`scripts/ci.sh` runs the CI gates locally and needs no cluster.

## Seeing the controls refuse something

The three manifests in `tests/` are valid Kubernetes but violate one rule each.
They are applied with `--dry-run=server`, so nothing is created, and the cluster
still evaluates them:

```bash
kubectl apply -n shop --dry-run=server -f tests/privileged-pod.yaml  # Pod Security
kubectl apply -n shop --dry-run=server -f tests/latest-tag-pod.yaml  # Kyverno
kubectl apply -n shop --dry-run=server -f tests/no-limits-pod.yaml   # Kyverno
```

The error names which layer refused the pod and why. `verify.sh` runs the same
three as part of its checks.

## Layout

```
app/                   the API and its Dockerfile
kind/                  cluster definition (two nodes, default CNI disabled)
manifests/base/        the insecure baseline, kept on purpose as the "before"
manifests/hardened/    namespace, service accounts, database and API
manifests/kyverno-policies/
manifests/network-policies/
manifests/secrets/     SealedSecrets (ciphertext, safe to commit)
scripts/               setup, build, seal, harden, verify, ci, teardown
tests/                 pods that must be rejected
docs/decisions.md      why each choice was made
```

## Versions

Kubernetes runs on Kind, with Calico v3.27.0, Kyverno v1.19.1 and Sealed
Secrets v0.40.0. The application base image is pinned by digest in
`app/Dockerfile`.
