# macOS support

AgentLocalCI 0.2 introduces beta macOS host support.

## Supported shape

- PowerShell 7.4 or newer runs the trusted controller.
- Git supplies the exact local commit and tree objects.
- Docker Desktop supplies a Linux Docker engine.
- Apple Silicon uses a native `linux/arm64` AgentLocalCI image.
- Intel Macs use `linux/amd64`.

Node.js and PowerShell archives in the trusted image are selected by Docker `TARGETARCH` and verified with architecture-specific SHA-256 checksums. The Ubuntu base is pinned by a multi-platform OCI index digest.

## Install

```bash
brew install powershell
brew install --cask docker
```

Open Docker Desktop and wait until this succeeds:

```bash
docker info
```

Then clone and install:

```bash
git clone https://github.com/arthuz-th/AgentLocalCI.git
cd AgentLocalCI
pwsh -NoProfile -File ./install.ps1
exec "$SHELL" -l
agentlocalci doctor --build-image
```

The default installation is under:

```text
~/Library/Application Support/AgentLocalCI
```

The installer adds one owner-marked block to `~/.zprofile`. Uninstall removes only that block. Use `-NoPath` to leave the profile untouched.

## Apple Silicon and Android builds

The controller and Java/npm/PowerShell stages are native ARM64. Android command-line packages are installed in the trusted image, but some Android build tools or third-party Gradle plugins may still distribute x86-only executables. Such repositories may require an amd64 Docker environment and are not universally certified by the macOS beta claim.

## Beta evidence and limitation

Release gates build the ARM64 image and run cross-platform controller, installer, provenance, cleanup, and Unix contract tests. A release must not claim physical-device or every-version macOS certification unless that test was actually performed and recorded.

Report macOS-specific failures with Mac model/chip, macOS version, Docker Desktop version, PowerShell version, Docker architecture, exact commit, and redacted report.
