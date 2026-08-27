# Architecture

AgentLocalCI has four phases.

## 1. Trusted host controller

PowerShell validates arguments, machine policy, repository root, pipeline schema, exact commit identity, resource limits, and the trusted image identity. A per-home controller lock prevents overlapping runs and maintenance.

## 2. Exact-tree source transport

Git for Windows resolves one lowercase 40-character commit SHA with hooks, global configuration, prompts, replacement objects, and optional locks disabled. The controller creates a new pack containing exactly the selected commit, its tree, and reachable trees/blobs while excluding parent history and rejecting gitlinks or reserved `.git` paths. A trusted seed container imports the pack, disables repository attributes and line-ending conversion, verifies the exact commit/tree, materializes source bytes, writes commit/tree markers outside the source directory, and removes temporary Git metadata.

No host checkout or host `.git` directory is mounted or copied, and validation stages receive no `.git` directory.

## 3. Dependency preparation

When a stage declares `needs: ["npm"]` or `needs: ["gradle"]`, the controller creates a per-run internal bridge network. Fetch containers can reach only a trusted dependency proxy on that network. The proxy has controlled egress and allows exact machine-policy hostnames on IPv4 port 443. A probe must prove common direct network paths are unavailable.

Prepared caches remain run-private seeds. Each validation stage receives its own fresh writable cache copy while networking is disabled; target changes are never promoted to another stage or run.

## 4. Offline validation and evidence

Stages run sequentially in fresh `network=none` containers. The root filesystem is read-only and the process is non-root. Each stage receives fresh run-owned source and cache volumes; source is recreated from the exact pack and cache copies are isolated from every other stage. A small evidence volume and bounded tmpfs are also writable, and all stage-owned volumes are removed afterward.

The controller owns timeouts, output bounds, redaction, report persistence, verdict mapping, and cleanup. Target code cannot modify the host report.

## Resource lifecycle

Each Docker resource carries:

- `io.agentlocalci.owner=agentlocalci`
- `io.agentlocalci.run=<run-id>`
- `io.agentlocalci.kind=<kind>`

State records the same tuple. Normal cleanup and crash recovery require exact agreement, delete containers before networks before volumes, and verify absence. Unknown resources are not guessed or force-deleted.

## Profiles

A profile is either:

- `acceptance: true`: success may serve as local acceptance evidence within its declared scope;
- `acceptance: false`: completion returns exit code 6 and is diagnostic only.

Declared gaps are part of the report. A pass never implies release, deployment, production safety, or tests that the profile did not run.
