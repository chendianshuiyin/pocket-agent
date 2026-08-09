#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"
out_dir="${1:-$repo_root/frontend/src/protocol/generated}"

mkdir -p "$out_dir"

args=(app-server generate-ts --out "$out_dir")
if [[ "${CODEX_POCKET_EXPERIMENTAL_SCHEMA:-0}" == "1" ]]; then
  args+=(--experimental)
fi

codex "${args[@]}"
echo "Generated Codex app-server TypeScript bindings in $out_dir"
