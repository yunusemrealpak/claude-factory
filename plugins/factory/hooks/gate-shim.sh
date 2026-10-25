#!/usr/bin/env bash
# gates/verify.sh - the project's gate entry point, banned for agents. The gate logic is in the factory plugin.
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
command -v factory-check >/dev/null 2>&1 || { echo "GATE RED: the factory plugin is not on PATH (factory-check)"; exit 1; }
exec factory-check "$@"
