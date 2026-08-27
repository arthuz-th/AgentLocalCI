# Security design

## Host isolation

Validation receives no host bind mount. Source is reconstructed inside Docker from a minimal exact-tree Git pack. A trusted seed verifies the commit/tree and removes temporary Git metadata before validation; target stages receive no `.git` directory. Containers have no Docker socket, device, published port, credential helper, SSH agent, `.env`, user profile, or unrelated checkout.

The runtime is non-root, read-only, capability-free, and protected by `no-new-privileges`. Every container is inspected before it starts; a mismatch is a safety failure. The trusted runner resolves working directories, lockfiles, Gradle wrappers, and relative executables to canonical paths inside the exact-tree mount, so a committed symbolic link cannot redirect those controller-selected paths outside the repository.

## Network isolation

Validation stages use Docker `network=none`.

Dependency preparation uses two networks by design:

- fetch containers: only the per-run internal isolated network;
- trusted proxy: the internal network plus Docker's default bridge for egress.

The proxy supports exact hostname HTTPS CONNECT on port 443, resolves IPv4 A records itself, rejects private/special address ranges, and connects to the resolved address to reduce DNS-rebinding ambiguity. It does not support arbitrary HTTP forwarding, IP-literal targets, wildcard domains, or non-443 ports.

A network probe must fail to reach the allowlisted host directly, public resolver IPs, Docker host aliases, link-local metadata, private gateways, and common Docker daemon ports while succeeding through the proxy.

## Secrets

AgentLocalCI is secretless by default. Environment names associated with credentials are denied, known token formats are rejected, inherited sensitive environment variables are removed, Git prompting is disabled, and logs are redacted before persistence.

Secret detection is defense in depth, not proof. Do not commit secrets or run secret-requiring tests in 0.1.

## Provenance

Only an exact local commit SHA is accepted. The controller records target commit, tree, object count, pack digest, pipeline digest, policy digest, controller identity, trusted image ID, and a hash of the repository path. The raw personal path is not written to the report.

## Cleanup

Run state and Docker inspection must agree on type, exact name, owner, run, and kind. Cleanup distinguishes absence from inspection failure and verifies absence after deletion. A dead controller may be recovered only after process ID and start time no longer identify a live process.

## Remaining risk

The Docker daemon and current Windows account are privileged parts of the trusted host boundary. Dependency publishers remain a supply-chain risk. Resource limits reduce but cannot eliminate denial of service or side channels.
