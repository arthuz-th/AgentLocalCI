# Current limitations

AgentLocalCI 0.1 alpha is deliberately narrow.

- Windows host only; PowerShell 7 and Docker Desktop with Linux containers are required.
- Project stages run sequentially; there is no DAG, matrix, retry policy, service graph, artifact upload, or distributed cache.
- Dependency preparation supports npm and Gradle only.
- The dependency proxy is IPv4-only, exact-hostname, HTTPS CONNECT port 443 only.
- No private registries, credentials, signed-in package feeds, cloud APIs, databases, browser farms, emulators, hardware devices, or deployment steps.
- No Git submodule initialization and no Git LFS download. The selected tree must already contain required blobs.
- No automatic fetch of missing commits, branches, tags, or pull requests.
- No macOS/Linux host installer yet.
- No remote trigger, daemon, webhook listener, scheduled service, or GitHub self-hosted runner mode.
- No target artifact export to the host in 0.1.
- The trusted image pins major tool distributions and checksums, but operating-system packages installed from snapshot repositories are not guaranteed bit-for-bit reproducible forever.
- Secret redaction catches representative formats, not every possible secret.
- Local acceptance cannot substitute for platform-specific cloud tests, protected environments, production smoke tests, human review, or release authorization.

"Universal" in the project goal means a generic project-defined local CI engine rather than an application-specific script. It does not mean every language, operating system, service, or workflow is supported in 0.1.
