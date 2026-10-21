#!/usr/bin/env bash
# Fail if throwaway agent/probe files were committed to the repository.
set -euo pipefail

bad="$(
  git ls-files |
    grep -E '(^|/)(zz_|tmp_|_scratch_|dbg_)' || true
)"
if [[ -n "$bad" ]]; then
  echo "error: scratch/probe files must not be committed:" >&2
  echo "$bad" >&2
  echo "Use descriptive test names, or keep throwaway scripts in /tmp." >&2
  exit 1
fi

# The transports that PLAN.md lists as planned (HTTP/2, WASI/browser) must
# stay documented as "not yet implemented", not silently advertised as done.
if grep -q 'WASI/browser transports are implemented' README.md; then
  echo "error: README advertises transports that are not implemented" >&2
  exit 1
fi

echo "repository hygiene: ok"
