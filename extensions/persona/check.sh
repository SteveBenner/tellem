#!/usr/bin/env bash
set -euo pipefail
command -v ruby >/dev/null 2>&1 || { echo "persona: ruby is not on PATH" >&2; exit 1; }
