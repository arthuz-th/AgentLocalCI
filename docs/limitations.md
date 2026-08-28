# Current limitations

AgentLocalCI 0.2 beta is deliberately narrower than a general-purpose hosted CI platform.

- Windows is supported; macOS and Linux host controllers/installers are beta.
- No physical Mac model or every Docker Desktop release is implied by the beta label.
- Project stages run sequentially; there is no DAG, matrix, retry policy, service graph, artifact upload, or distributed cache.
- Automatic dependency preparation supports npm and Gradle only.
- Automatic setup recognizes common npm scripts and common Gradle wrapper locations; it does not invent acceptance for unknown project types.
- The dependency proxy is IPv4-only, exact-hostname, HTTPS CONNECT port 443 only.
- No private registries, credentials, signed-in package feeds, cloud APIs, databases, browser farms, emulators, hardware devices, signing, or deployment steps.
- Some Android or third-party build tools may remain x86-only even when the controller image is native ARM64.
- No Git submodule initialization and no Git LFS download. Required blobs must already exist locally.
- No automatic fetch of missing commits, branches, tags, or pull requests.
- No remote trigger, daemon, webhook listener, scheduled service, or GitHub self-hosted runner mode.
- No target artifact export to the host.
- The trusted image pins base/tool artifacts and checksums, but operating-system repository packages are not guaranteed bit-for-bit reproducible forever.
- Secret redaction catches representative formats, not every possible secret.
- Local acceptance cannot substitute for independent hosted checks, platform-specific cloud tests, protected environments, production smoke tests, human review, or release authorization.

“Cross-platform” means the trusted controller can run on Windows, macOS, and Linux while project stages execute in a locked-down Linux container. It does not mean every host-native tool, language, operating system, service, or workflow is available.
