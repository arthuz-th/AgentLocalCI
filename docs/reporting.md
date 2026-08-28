# Reports and evidence

Each run stores local state under the selected AgentLocalCI home:

```text
runtime/runs/<RUN_ID>/
  state.json
  report.json
  summary.md
  report.html
  logs/
```

Open the latest readable report with:

```powershell
agentlocalci report --open
```

The HTML report is self-contained and includes no external JavaScript, fonts, images, or network requests. The JSON report remains the machine-readable source of truth.

Reports contain the exact commit and tree, pack digest and object count, host platform/architecture, controller and native Linux image architecture, profile scope and declared gaps, pipeline/policy/repository-path fingerprints, stage timing and bounded log filenames, safety assertions, cleanup proof, result, and exit code.

The raw repository path is not written; only a SHA-256 fingerprint is stored. Logs are redacted before persistence. Target code writes only to disposable Docker volumes and cannot write the host report.

## Interpret results narrowly

- `Passed`: every configured stage passed and cleanup was proven complete for an acceptance profile.
- `DiagnosticOnly`: stages completed for a non-acceptance profile; exit code 6 prevents accidental promotion.
- `Failed`: project validation failed.
- `InfrastructureFailed`: controller/Docker/local infrastructure failed.
- `SafetyBlocked`: a boundary could not be proven.
- `CleanupFailed`: acceptance is denied even when stages succeeded.

A report proves only the declared profile on the exact commit. It does not authorize merge, release, deployment, payment, production, or tests listed as gaps.
