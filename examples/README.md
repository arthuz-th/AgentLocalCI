# Configuration examples

These examples show project configuration only. Copy the relevant `.agentlocalci/pipeline.yml` into the root of your own repository and adapt command names, paths, exact dependency hosts, timeouts, and declared gaps.

- `generic-powershell`: no dependency preparation; runs a committed PowerShell test script offline.
- `node-basic`: npm cache preparation followed by offline test and build stages.
- `nextjs`: npm preparation with lint, test, and production build stages; deployment and hosted services remain outside the profile.
- `android-gradle`: Gradle cache preparation with an offline wrapper check; emulator/device tests remain outside the profile.

A repository cannot broaden the user's machine policy. Every `dependency_hosts` entry must also appear in `%LOCALAPPDATA%\AgentLocalCI\policy.yml`.
