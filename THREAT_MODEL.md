# Threat model

## Security objective

Run code from one exact local Git commit while preventing that code from reading or modifying host files, credentials, Docker control interfaces, other project checkouts, personal directories, or the network during validation.

## Trusted computing base

AgentLocalCI trusts:

- the Windows, macOS, or Linux host kernel and administrator;
- the current local user account;
- the local Linux Docker engine, VM/runtime, and daemon operator;
- Git and PowerShell 7.4+;
- AgentLocalCI controller source and its pinned multi-architecture trusted image definition;
- certificate authorities installed in the trusted image;
- dependency hosts explicitly allowed by machine policy during preparation.

A user or process with Docker daemon access can create, inspect, relabel, or delete Docker resources and is inside the trusted boundary.

## Untrusted inputs

- the selected repository tree and committed pipeline;
- build scripts, package manifests, lockfiles, tests, generated output, stdout, and stderr;
- dependency content returned by allowed public hosts;
- stale or partially written local run state;
- user shell profiles and Git hook paths, except for exact AgentLocalCI-owned marker blocks/files.

## Boundary

### Source

The advanced controller accepts only a lowercase 40-character SHA that resolves locally to a commit. Beginner `check` first requires a clean working tree, then resolves the same full commit SHA. The controller generates a minimal pack containing that commit's exact tree and reachable tree/blob objects. It does not copy parent commits, refs, remotes, hooks, global Git configuration, credentials, or the host `.git` directory.

A trusted seed container imports and verifies the pack, materializes bytes with repository attributes and conversion filters disabled, writes commit/tree markers outside source, and removes `.git` before target execution.

### Runtime

Validation containers run non-root with a read-only root, dropped capabilities, `no-new-privileges`, bounded writable tmpfs/named volumes, no host bind mounts, no Docker socket, no devices, no published ports, no credentials, and `network=none`. Controller-selected paths are resolved canonically inside the exact-tree mount; symbolic-link escapes are safety violations.

### Dependencies

Dependency preparation is separate and trusted. Fetch containers use a per-run internal network and can reach only the trusted proxy. The proxy has controlled egress through Docker's default bridge and permits exact allowlisted IPv4 HTTPS destinations on port 443. Direct paths to public IPs, host aliases, metadata IPs, gateways, and daemon ports are probed and must fail.

Prepared npm and Gradle caches remain run-private seeds. Each validation stage gets a fresh writable copy while networking is disabled. npm lifecycle scripts are disabled during preparation and offline installation.

### Installer and hooks

Installation accepts only a narrow non-symlink/reparse root, verifies controller inventories, and manages PATH through either the Windows user environment or one exact owner-marked shell-profile block. Uninstall requires a valid ownership manifest and preserves a recoverable backup.

The pre-push feature is opt-in. It writes or removes only a hook containing the exact AgentLocalCI ownership marker and refuses an existing foreign hook.

### Cleanup

Every container, network, and volume is recorded with type, exact name, owner, run, and kind. Cleanup verifies process death for recovery, exact labels, deletion order, and post-delete absence. Ambiguous, conflicting, unclaimed, or uninspectable resources are retained and return cleanup failure.

## Defended threats

- malicious repository code attempting host filesystem, Docker daemon, device, credential, or direct network access;
- dependency fetches to non-allowlisted/private targets;
- branch/ref substitution, abbreviated-SHA confusion, and dirty-tree ambiguity;
- accidental inclusion of host checkout, Git history, remote metadata, or personal paths;
- shell-command-string pipeline fields;
- broad cleanup, broad uninstall, shell-profile overwrite, or foreign-hook overwrite;
- representative credential patterns surviving config/log/report validation.

## Out of scope

- a malicious host administrator, current-user process, Docker daemon operator, hypervisor, kernel, firmware, or compromised trusted toolchain;
- side channels and denial of service within host limits;
- malicious code run outside AgentLocalCI;
- secrets deliberately committed in repository blobs or dependencies;
- proving a dependency trustworthy merely because its hostname is allowed;
- remote pull-request automation, production deployment authorization, and perfect secret detection;
- universal compatibility with every x86-only project tool on ARM64 hosts.

## Fail-closed rules

A run is not an acceptance pass when target resolution, policy validation, runtime inspection, network probing, report persistence, or cleanup proof fails. Cleanup and safety failures remain distinct from ordinary project test failures.
