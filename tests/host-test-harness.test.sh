#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/scratch space"
# Model sudo's environment reset without invoking privileged namespace tools.
cat > "$work/bin/sudo" <<'SH'
#!/usr/bin/env bash
while [[ $# -gt 0 && "$1" != env ]]; do shift; done
[[ $# -gt 0 ]] || exit 90
exec env -i HOME="$HOME" PATH="$PATH" "$@"
SH
chmod +x "$work/bin/sudo"
actual="$(PATH="$work/bin:$PATH" TMPDIR="$work/scratch space" \
  "$here/ci/run-host-tests.sh" bash -c 'printf "%s|%s" "$TMPDIR" "$LC_ALL"; f=$(mktemp); rm "$f"')"
[[ "$actual" == "$work/scratch space|C" ]]
if PATH="$work/bin:$PATH" TMPDIR="$work/scratch space" \
  "$here/ci/run-host-tests.sh" bash -c 'exit 42'; then
  echo 'lost command failure' >&2; exit 1
else
  [[ $? -eq 42 ]]
fi
if TMPDIR=relative "$here/ci/run-host-tests.sh" true; then
  echo 'accepted relative scratch directory' >&2; exit 1
fi
printf 'PASS host harness preserves scratch, locale and exit status\n'
