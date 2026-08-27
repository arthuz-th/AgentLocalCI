# Security policy

## Supported versions

AgentLocalCI is pre-1.0. Security fixes are applied to the latest published release only.

| Version | Supported |
|---|---|
| latest 0.1.x alpha | Yes |
| older snapshots | No |

## Reporting a vulnerability

Do not open a public issue for a suspected vulnerability, credential exposure, cleanup bypass, host escape, dependency-proxy bypass, or provenance failure.

Use the repository's **Security → Report a vulnerability** private advisory form. Include:

- affected commit or release;
- Windows, PowerShell, Git, Docker Desktop, and Docker Engine versions;
- the exact command and minimal repository fixture;
- expected versus observed boundary;
- whether any host file, credential, network endpoint, Docker resource, or report was exposed;
- a redacted proof of concept.

Do not include real secrets or private repository contents. Use synthetic canaries.

## Response goals

Maintainers will acknowledge a complete report, assess impact, coordinate a fix and disclosure, and credit the reporter unless anonymity is requested. No response-time guarantee is offered for this volunteer project.

## Security scope

High-priority reports include:

- target code gaining access to host files, Docker socket, devices, credentials, or host ports;
- validation networking that is not `none`;
- dependency traffic escaping the exact HTTPS hostname allowlist;
- cleanup deleting a resource without exact owner/run/kind proof;
- accepting a branch, tag, abbreviation, uppercase SHA, missing object, or non-commit as the target;
- source history, remotes, host checkout, or private metadata entering the target container;
- secrets surviving report/log redaction or entering the public repository.

The same Windows account, host administrator, and Docker daemon operator are trusted. Reports that require an already-malicious trusted host operator may be documented rather than treated as a sandbox escape.
