#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
skill_dir="$repo_root/skills/playwright-my-chrome"

command -v shellcheck >/dev/null 2>&1 || {
  echo "ERROR: shellcheck is required." >&2
  exit 1
}

while IFS= read -r script; do
  bash -n "$script"
  shellcheck "$script"
done < <(/usr/bin/find "$skill_dir/scripts" "$repo_root/tests" -type f -name '*.sh' -print)

python3 "$repo_root/tests/validate_skill.py"
echo "Lint checks passed."
