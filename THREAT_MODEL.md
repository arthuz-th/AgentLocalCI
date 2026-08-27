# Threat model

## Security objective

Run code from one exact local Git commit while preventing that code from reading or modifying host files, credentials, Docker control interfaces, other project checkouts, personal directories, or the network during validation.

## Trusted computing base

AgentLocalCI trusts:

- the Windows host kernel and administrator;
- the current Windows user account;
- Docker Desktop, its Linux VM, container runtime, and daemon operator;
- Git for Windows and PowerShell 7;
- AgentLocalCI controller source and its pinned trusted image definition;
- certificate authorities installed in the trusted image;
- dependency hosts explicitly allowed by machine policy during preparation.

A user or process with Docker daemon access can create, inspect, relabel, or delete Docker resources and is inside the trusted boundary.

## Untrusted inputs

- the selected repository tree;
- `.agentlocalci/pipeline.yml` inside that tree;
- build scripts, package manifests, lockfiles, tests, generated output, stdout, and stderr;
- dependency content returned by allowed public hosts;
- stale or partially written local run state.

## Boundary

### Source

The controller accepts only a lowercase 40-character SHA that resolves locally to a commit. It generates a minimal object pack containing that commit's exact tree and reachable tree/blob objects. It does not copy the host checkout, parent commits, refs, remotes, hooks, global Git configuration, credentials, or the host `.git` directory.

A trusted seed container uses a temporary minimal Git repository only to import the pack, verify the exact commit and tree, and materialize bytes with repository attributes and conversion filters disabled. It then writes immutable commit/tree markers outside the source directory and removes `.git` before any target stage starts. Validation containers receive source files and trusted markers, but no Git metadata, refs, remotes, hooks, or parent history.

### Runtime

Validation containers run non-root with a read-only root, dropped capabilities, `no-new-privileges`, bounded writable `tmpfs`, named volumes only, no host bind mounts, no Docker socket, no device mappings, no published ports, no credentials, and `network=none`. Controller-selected working directories, dependency files, wrappers, and relative executables are resolved canonically inside the exact-tree mount; symbolic-link escapes are classified as safety violations before target code starts.

### Dependencies

Dependency preparation is a separate trusted phase. Fetch containers use a per-run internal network and can reach only a trusted proxy. The proxy has controlled egress through Docker's default bridge and permits exact allowlisted IPv4 HTTPS destinations on port 443. Direct access from fetch containers to public IPs, Docker host aliases, metadata IPs, gateways, and common daemon ports is probed and must fail.

Prepared npm and Gradle caches remain run-private seeds. Each validation stage receives a fresh writable copy while networking is disabled, and stage-modified cache contents are never promoted to another stage or run. Package lifecycle scripts are disabled during npm preparation and offline installation.

### Cleanup

Every created container, network, and volume is recorded with type, exact name, owner, run, and kind. Cleanup verifies process death for crash recovery, exact labels, deletion order, and post-delete absence. Ambiguous, conflicting, unclaimed, or uninspectable resources are retained and return cleanup failure.

## Defended threats

- malicious repository code attempting host filesystem access;
- access to Docker daemon or host devices;
- direct validation-stage network exfiltration;
- dependency fetches to non-allowlisted hosts or private IPv4 ranges;
- branch/ref substitution and abbreviated-SHA confusion;
- accidental inclusion of the host checkout or Git history;
- shell-command-string fields in pipeline configuration;
- obvious credential patterns in policy, pipeline, logs, and reports;
- over-broad Docker cleanup.

## Out of scope

- a malicious Windows administrator, current-user process, Docker daemon operator, hypervisor, kernel, firmware, or compromised trusted toolchain;
- side channels and denial of service within host resource limits;
- malicious code executed outside AgentLocalCI;
- secrets deliberately embedded in repository blobs or dependencies;
- proving that a dependency is trustworthy merely because its hostname is allowed;
- remote pull-request automation;
- production deployment authorization;
- perfect secret detection.

## Fail-closed rules

A run is not an acceptance pass when target resolution, policy validation, runtime inspection, network probing, report persistence, or cleanup proof fails. Cleanup failure uses a distinct exit code and is not downgraded to an ordinary test failure.
