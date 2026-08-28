# Security policy

## Supported versions

AgentLocalCI is pre-1.0. Security fixes are applied to the latest published release only.

| Version | Supported |
|---|---|
| latest 0.2.x beta | Yes |
| 0.1.x alpha and older snapshots | No |

## Reporting a vulnerability

Do not open a public issue for a suspected credential exposure, cleanup bypass, host escape, dependency-proxy bypass, provenance failure, unsafe installer/profile mutation, or hook ownership bypass.

Use the repository's **Security → Report a vulnerability** private advisory form. Include:

- affected commit or release;
- host OS/architecture, PowerShell, Git, Docker Desktop/Engine versions;
- exact command and minimal synthetic repository fixture;
- expected versus observed boundary;
- whether any host file, credential, network endpoint, Docker resource, hook, shell profile, or report was exposed;
- a redacted proof of concept.

Do not include real secrets or private repository contents. Use synthetic canaries.

## Security scope

High-priority reports include:

- target code gaining host-file, Docker-socket, device, credential, or host-port access;
- validation networking that is not `none`;
- dependency traffic escaping the exact HTTPS allowlist;
- cleanup deleting without exact owner/run/kind proof;
- accepting a branch, tag, abbreviation, uppercase SHA, missing object, non-commit, or dirty tree through an easy command;
- source history, remotes, host checkout, or private metadata entering validation;
- installer or uninstall mutation outside owned paths/profile markers;
- overwriting or removing a foreign Git hook;
- secrets surviving report/log redaction or entering the public repository.

The current local user, host administrator, and Docker daemon operator are trusted. A malicious trusted host operator is outside the sandbox boundary.
