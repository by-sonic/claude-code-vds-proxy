#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

scripts=()
while IFS= read -r -d '' script; do
  scripts+=("$script")
done < <(find . -type f -name '*.sh' -print0)
for script in "${scripts[@]}"; do
  bash -n "$script"
done

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -x -s bash "${scripts[@]}"
fi

./install.sh --help >/dev/null
./uninstall.sh --help >/dev/null
./maintain.sh --help >/dev/null

if grep -REn --exclude-dir=.git \
  '(BEGIN (RSA|OPENSSH|EC) PRIVATE KEY|gh[oprsu]_[A-Za-z0-9_]{20,}|sk-ant-[A-Za-z0-9_-]{20,})' .; then
  echo "Potential credential detected" >&2
  exit 1
fi

if grep -REn --exclude-dir=.git \
  '(^|[^0-9])(45\.88\.175\.210|194\.154\.27\.227)([^0-9]|$)' .; then
  echo "Private deployment IP detected" >&2
  exit 1
fi

echo "Static checks passed for ${#scripts[@]} shell scripts."
