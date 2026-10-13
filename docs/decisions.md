# Decisions

Short records of the choices that shaped this lab: the context, the decision and
what was considered instead.

## Calico instead of the default CNI

NetworkPolicies are only meaningful when the network plugin enforces them. The
cluster disables Kind's default CNI and installs Calico, so a policy that is not
enforced fails loudly instead of being silently ignored. Cilium would do the same
job and adds capabilities this lab does not need.

## Pod Security Admission and Kyverno together

They cover different things. Pod Security Admission is built in and enforces the
pod-level profile (`restricted`) with one namespace label. Kyverno covers what it
cannot: image tags, resource limits and mutation. Using only Kyverno would mean
rewriting rules Kubernetes already ships; using only Pod Security would leave
images unchecked.

## Kyverno failure action at rule level

`spec.validationFailureAction` is deprecated. The policies set
`validate.failureAction: Enforce` on each rule, which is the supported form and
avoids a silent downgrade to audit on a future upgrade.

## Sealed Secrets rather than a plain Secret

A Kubernetes Secret is base64, not encryption, so it cannot live in Git. A
SealedSecret is ciphertext that only the in-cluster controller can read, which
keeps the password in version control without exposing it. An external manager
such as Vault would be the choice with more than one cluster; it is more moving
parts than this lab needs.

## The API talks to the database over a named Service

The API resolves `postgres` through DNS, which is why the DNS egress rule exists
before any other rule. Without it, the default-deny policy would break name
resolution and every connection would fail for a reason that looks unrelated.

## An ingress rule for the node

Readiness probes come from the kubelet on the node, outside the pod network, so a
default-deny ingress would make a healthy pod look unready. The policy allows the
Kind node subnet on the API port only.

## The insecure baseline stays in the repository

It is the "before" of every comparison and the thing the policies are tested
against. It is excluded from the Trivy manifest gate, because it is meant to
fail, and its headers say so in the file itself.

## Tools pinned and verified in CI

The workflow pins the checkout action by commit SHA, and downloads gitleaks and
Trivy at a fixed version, checking the published SHA-256 before running them. A
tag can be moved; a commit and a checksum cannot.

## One gitleaks exception, for ciphertext only

The secret scanner flags the SealedSecret, because an encrypted value looks like
a credential. `.gitleaks.toml` allows that one path pattern and nothing else; a
plaintext key dropped anywhere in the repository is still caught, which was
checked with a deliberate test file before the exception was committed.
