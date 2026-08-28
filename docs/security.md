# Security design

## Host isolation

Validation receives no host bind mount. Source is reconstructed inside Docker from a minimal exact-tree Git pack. A trusted seed verifies the commit/tree and removes temporary Git metadata before validation; target stages receive no `.git` directory. Containers receive no Docker socket, device, published port, credential helper, SSH agent, `.env`, user profile, or unrelated checkout.

The runtime is non-root, read-only, capability-free, and protected by `no-new-privileges`. Every container is inspected before start. The runner resolves working directories, lockfiles, wrappers, and relative executables canonically inside the exact-tree mount, so committed symbolic links cannot redirect controller-selected paths outside source.

## Network isolation

Validation always uses Docker `network=none`.

Dependency preparation uses a run-private internal network. Fetch containers reach only the trusted proxy; the proxy also has Docker bridge egress. It accepts exact hostname HTTPS CONNECT on port 443, resolves IPv4 itself, rejects private/special ranges, and connects to the resolved address. Arbitrary HTTP, wildcard domains, IP literals, credentials, IPv6 destinations, and non-443 ports are unsupported.

A probe must fail to reach the allowlisted host directly, public resolver IPs, host aliases, metadata, private gateways, and common Docker daemon ports while succeeding through the proxy.

## Secrets

AgentLocalCI is secretless by default. Credential-like environment names are denied, representative token formats are rejected, inherited sensitive variables are removed, Git prompting is disabled, and logs are redacted before persistence.

Secret detection is defense in depth, not proof. Never commit secrets or use AgentLocalCI for tests that require credentials.

## Provenance and beginner safety

Advanced runs accept only an exact local commit SHA. `check` and `quickstart` additionally require a clean tree before resolving exact HEAD. Automatic npm setup invokes detected script names by argv; it does not copy script bodies into pipeline commands. Optional automatic commit is limited to the generated pipeline as the sole change.

Reports record commit/tree, pack digest, pipeline/policy/controller/image fingerprints, host/image architecture, and a hash—not the raw value—of the repository path.

## Installer and hook ownership

Install roots must be narrow and free of symlink/reparse ancestors. Existing controller identities are inventory-verified before reuse. Unix PATH edits are bounded by exact AgentLocalCI markers. Uninstall requires the product manifest and preserves backups.

The pre-push hook manager refuses to overwrite or remove a hook without the AgentLocalCI owner marker.

## Cleanup

State and Docker inspection must agree on type, exact name, owner, run, and kind. Cleanup distinguishes absence from inspection failure and verifies absence after deletion. Dead-controller recovery also checks process ID and start time.

## Remaining risk

The current local account, host administrator, Docker daemon operator, and host kernel are privileged trusted components. Dependency publishers remain a supply-chain risk. Resource limits reduce but cannot eliminate denial of service or side channels. A local pass is not independent verification away from the contributor machine.
