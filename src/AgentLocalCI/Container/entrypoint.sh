#!/usr/bin/env bash
set -euo pipefail

if [[ "$(id -u)" == "0" ]]; then
  echo "AgentLocalCI refuses to execute repository code as root." >&2
  exit 64
fi
if [[ "${AGENTLOCALCI_EXECUTION_BOUNDARY:-}" != "unprivileged-linux-container" ]]; then
  echo "AgentLocalCI execution-boundary marker is absent or invalid." >&2
  exit 65
fi
if [[ "${AGENTLOCALCI_ARTIFACT_ROOT:-}" != "/evidence" ]]; then
  echo "AgentLocalCI artifact-root marker is absent or invalid." >&2
  exit 66
fi
if [[ "$#" -eq 0 ]]; then
  echo "AgentLocalCI requires an explicit argv command." >&2
  exit 67
fi
exec "$@"
