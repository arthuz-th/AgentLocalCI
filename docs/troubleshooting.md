# Troubleshooting

## `doctor` fails

Run:

```powershell
agentlocalci doctor --build-image
```

Confirm PowerShell 7.4+, Git for Windows, Docker Desktop, Linux container mode, sufficient disk, and an enabled policy. The doctor creates and removes an isolated test network; a cleanup failure must be resolved before running project code.

## Exact SHA rejected

Use:

```powershell
$sha = (git rev-parse HEAD).Trim()
$sha.Length
```

The value must be a lowercase 40-character commit SHA that already exists locally. AgentLocalCI intentionally rejects `HEAD`, branch names, tags, abbreviations, uppercase values, and missing objects.

## Dependency preparation cannot reach a host

Add every exact redirect/CDN/registry hostname required by the lockfile to both:

- project `dependency_hosts`;
- user machine policy `allowed_dependency_hosts`.

Wildcards, IP literals, private addresses, HTTP, and non-443 ports are unsupported. The proxy is IPv4-only in 0.1.

## Validation tries to access the network

That is expected to fail. Validation always uses `network=none`. Move public dependency retrieval into a supported dependency-preparation mode and make the validation command offline.

## `clean` returns exit code 5

Do not delete broad Docker resources manually. Read the JSON failure, inspect the exact resource, and verify its owner/run/kind labels. AgentLocalCI retains ambiguous resources to avoid deleting unrelated data.

After resolving the mismatch, run:

```powershell
agentlocalci clean
```

Use `clean --images` only when no run is active and you intend to remove verified AgentLocalCI trusted images and build contexts.

## A diagnostic profile returns 6

That is expected. `acceptance: false` profiles are useful for fast feedback but cannot be mistaken for completion evidence.
