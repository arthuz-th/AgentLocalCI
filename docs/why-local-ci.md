# Why local CI?

AgentLocalCI exists because “run the checks before pushing” is valuable even when a project already has hosted CI.

## The practical reasons

### 1. Routine jobs run outside GitHub Actions

An AgentLocalCI run uses the developer's computer and local Docker engine. The run itself does not submit a GitHub Actions job and therefore does not consume GitHub Actions hosted-runner minutes. Local electricity, hardware, disk, downloads, and maintenance still have costs.

### 2. Feedback starts immediately

A developer can run `agentlocalci check` before opening a pull request. There is no hosted queue and no need to push a broken intermediate commit merely to see workflow output.

### 3. The evidence names immutable source

`check` refuses dirty trees and resolves the full current commit. The report records the exact commit, tree, pack digest, policy, pipeline, image, stages, and cleanup outcome.

### 4. Validation is deliberately disconnected

Dependency preparation is separated from project validation. Validation uses `network=none`, receives no host repository mount or Docker socket, and receives no Git, cloud, SSH, package-feed, or deployment credential.

### 5. It is useful for private or sensitive work

Source and redacted reports stay on the local machine until the user deliberately shares them. That does not make a compromised host safe; the local user, administrator, and Docker daemon remain trusted.

### 6. It can enforce a local habit

The optional owned pre-push hook runs an AgentLocalCI profile before Git pushes. It is opt-in, removable, and refuses to overwrite an existing foreign hook.

## Why keep hosted CI?

Hosted CI still provides benefits that a local machine cannot honestly claim:

- pull-request status shared with every collaborator;
- branch protection integration;
- independent execution away from the contributor machine;
- hosted Windows/macOS/Linux and version matrices;
- organization-wide audit and retention;
- release publishing, cloud credentials, protected environments, and deployment.

## Recommended architecture

Use two layers:

1. **AgentLocalCI:** fast local exact-commit checks on every commit or push.
2. **Hosted CI:** a smaller authoritative workflow for shared status, matrices, releases, and deployment.

This reduces avoidable hosted work without pretending a local result proves everything a hosted or production system can prove.
