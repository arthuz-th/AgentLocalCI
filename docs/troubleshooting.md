# Troubleshooting

## Start with guided diagnostics

```powershell
agentlocalci doctor --build-image
```

Every failed check includes a suggested fix. On macOS, confirm native PowerShell, Git/command-line tools, Docker Desktop, and that `docker info` reports a Linux amd64 or arm64 engine.

## `check` says the working tree is dirty

This is intentional. AgentLocalCI reports immutable committed source only.

```powershell
git status
git add <reviewed files>
git commit
agentlocalci check
```

Stash or discard changes instead when they should not be committed.

## First-time setup stops after creating a file

Run `agentlocalci quickstart --commit` only when AgentLocalCI may create a commit containing exactly `.agentlocalci/pipeline.yml`. It refuses all broader staged or working-tree changes.

## Dependency preparation cannot reach a host

Add every exact redirect/CDN/registry hostname required by the lockfile to both project `dependency_hosts` and machine-policy `allowed_dependency_hosts`. Wildcards, IP literals, private addresses, HTTP, IPv6 destinations, and non-443 ports are unsupported.

## Validation tries to access the network

That is expected to fail. Validation always uses `network=none`. Move public dependency retrieval into npm or Gradle preparation and make validation offline.

## `clean` returns exit code 5

Do not delete broad Docker resources. Inspect the exact resource and verify owner/run/kind labels. AgentLocalCI retains ambiguity deliberately. After resolving it, run `agentlocalci clean`.

## Pre-push hook conflict

AgentLocalCI never overwrites a foreign pre-push hook. Integrate the `agentlocalci check` command manually into the existing hook, or keep using the existing hook without AgentLocalCI ownership.

## macOS Apple Silicon build uses an x86-only dependency

The AgentLocalCI image itself is native ARM64, but a project dependency may not be. Use an amd64 Docker environment for that project or replace the x86-only tool. Report the limitation rather than claiming a native pass.
