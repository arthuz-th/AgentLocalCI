# Architecture

AgentLocalCI has four execution phases and a beginner-facing orchestration layer.

## Guided orchestration

`quickstart` runs doctor checks, detects npm/Gradle configuration, optionally creates one narrowly scoped config commit, resolves exact `HEAD`, runs the profile, and can open the HTML report. `check` performs only the exact-HEAD gate and refuses dirty trees. Advanced `run --sha` remains available for automation.

## 1. Trusted host controller

PowerShell 7.4+ runs on Windows, macOS, or Linux. It validates arguments, machine policy, repository root, pipeline schema, exact commit identity, resource limits, and trusted image architecture/identity. A per-home lock prevents overlapping runs and maintenance.

Host-specific code is limited to path comparison, null device, home/profile locations, RAM/disk discovery, report opening, and installation. Project validation is always Linux-container based.

## 2. Exact-tree source transport

Git resolves one lowercase 40-character commit with hooks, global configuration, prompts, replacement objects, and optional locks disabled. The controller packs exactly the selected commit and reachable tree/blob objects while excluding parent history and rejecting gitlinks or reserved `.git` paths.

A trusted seed container verifies the commit/tree, materializes bytes, writes provenance markers outside source, and removes temporary Git metadata. Validation receives no host checkout, remote metadata, or `.git` directory.

## 3. Dependency preparation

When a stage needs npm or Gradle, the controller creates a run-private internal bridge. Fetch containers reach only a trusted exact-host HTTPS proxy. A probe must show common direct endpoints are unavailable. Prepared caches are disposable and copied separately for every validation stage.

## 4. Offline validation and evidence

Stages run sequentially in fresh `network=none`, non-root, read-only-root containers with dropped capabilities and `no-new-privileges`. No host bind, Docker socket, device, credential, or port is supplied.

The controller owns timeouts, output bounds, redaction, JSON/Markdown/HTML reporting, verdict mapping, and cleanup. Target code cannot modify host reports.

## Multi-architecture image

The OCI base is pinned by a multi-platform digest. Docker `TARGETARCH` selects checksum-pinned Node and PowerShell archives for `amd64` or `arm64`; Java is resolved from the architecture-native distribution. Image inspection must match the current Docker engine architecture.

## Resource lifecycle

Every Docker resource records `owner`, `run`, and `kind` labels and the same tuple in state. Cleanup requires exact agreement, removes containers before networks before volumes, and verifies absence. Unknown resources are retained.
