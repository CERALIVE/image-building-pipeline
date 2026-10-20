#!/usr/bin/env bash
# Offline brand asset contract; no access to the private brand repository needed.
# Profile: contract-test (docs/shell-profiles.md).
# shellcheck shell=bash

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_DIR="$(cd "${HERE}/.." && pwd)"
# shellcheck source=lib/assertions.sh
source "${HERE}/lib/assertions.sh"

WORK="$(mktemp -d)"
SAVED="$(mktemp)"
RESTORE_FILE=""
trap 'if [[ -n "${RESTORE_FILE}" ]]; then cp "${SAVED}" "${RESTORE_FILE}"; fi; rm -rf "${WORK}"; rm -f "${SAVED}"' EXIT

verify_brand() {
  python3 - "$1" <<'PY'
import json
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys

root = Path(sys.argv[1])
errors = []
try:
    lock = json.loads((root / "brand-assets.lock.json").read_text())
except (OSError, ValueError) as error:
    print(f"brand-assets.lock.json: {error}")
    sys.exit(1)
if not isinstance(lock, dict):
    print("brand-assets.lock.json: expected an object")
    sys.exit(1)
if type(lock.get("schema")) is not int or lock["schema"] != 1:
    errors.append("brand-assets.lock.json: schema must be 1")
for key, pattern in [
    ("tag", r"v\d{4}\.\d{1,2}\.\d+"),
    ("commit", r"[a-fA-F0-9]{40}"),
    ("tarballSha256", r"[a-fA-F0-9]{64}"),
]:
    if not isinstance(lock.get(key), str) or not re.fullmatch(pattern, lock[key]):
        errors.append(f"brand-assets.lock.json: invalid {key}")
if lock.get("source") != "CERALIVE/ceralive-brand":
    errors.append("brand-assets.lock.json: invalid source")
if lock.get("tarball") != f"ceralive-brand-{str(lock.get('tag', ''))[1:]}.tar.gz":
    errors.append("brand-assets.lock.json: invalid tarball")
if "postSync" in lock:
    errors.append("brand-assets.lock.json: portal must not have postSync")
files = lock.get("files")
if not isinstance(files, list) or len(files) != 1:
    errors.append("brand-assets.lock.json: expected exactly one file")
    files = files if isinstance(files, list) else []
try:
    notice = (root / "BRAND-ASSETS-NOTICE.md").read_text().splitlines()
except OSError as error:
    errors.append(f"BRAND-ASSETS-NOTICE.md: {error}")
    notice = []
listed = set()
brand_dirs = set()
for entry in files:
    to = entry.get("to") if isinstance(entry, dict) else None
    if not isinstance(to, str) or not to or PurePosixPath(to).is_absolute() or ".." in to.split("/") or "\\" in to:
        errors.append(f"brand-assets.lock.json: unsafe to: {to!r}")
        continue
    listed.add(to)
    path = root / to
    if "/brand/" in to:
        brand_dirs.add(path.parent)
    if not path.is_file():
        errors.append(f"{to}: missing file")
    else:
        result = subprocess.run(["sha256sum", "--", str(path)], capture_output=True, text=True)
        if result.returncode or result.stdout.split()[0] != entry.get("sha256"):
            errors.append(f"{to}: sha256 mismatch")
    if f"- {to}" not in notice:
        errors.append(f"BRAND-ASSETS-NOTICE.md: missing - {to}")
if files != [{
    "from": "exports/svg/ceralive-mark-small-dark.svg",
    "to": "mkosi/runtime/brand/ceralive-mark-small-dark.svg",
    "sha256": files[0].get("sha256") if files and isinstance(files[0], dict) else None,
}]:
    errors.append("brand-assets.lock.json: expected the small dark portal mark mapping")
for directory in brand_dirs:
    for path in directory.rglob("*"):
        if path.is_file() and path.relative_to(root).as_posix() not in listed:
            errors.append(f"{path.relative_to(root)}: orphan brand file")
for error in errors:
    print(error)
sys.exit(bool(errors))
PY
}

echo "== Brand assets: lock, checksums, notice and installer =="
if verify_brand "${PIPELINE_DIR}" >"${WORK}/actual.log" 2>&1; then
  ok "vendored brand assets match the schema-1 lock and notice"
else
  bad "brand asset integrity"
  cat "${WORK}/actual.log"
fi

if grep -qF "install -D -m 0644 \"\${src}/brand/ceralive-mark-small-dark.svg\" /usr/share/ceralive/brand/ceralive-mark-small-dark.svg" \
  "${PIPELINE_DIR}/mkosi/customize/postinst.d/networking.sh"; then
  ok "setup_provisioning installs the portal brand mark"
else
  bad "setup_provisioning must install the portal brand mark"
fi

FIXTURE="${WORK}/consumer"
mkdir -p "${FIXTURE}/mkosi/runtime"
cp "${PIPELINE_DIR}/brand-assets.lock.json" "${PIPELINE_DIR}/BRAND-ASSETS-NOTICE.md" "${FIXTURE}/"
cp -R "${PIPELINE_DIR}/mkosi/runtime/brand" "${FIXTURE}/mkosi/runtime/"
MARK="${FIXTURE}/mkosi/runtime/brand/ceralive-mark-small-dark.svg"

RESTORE_FILE="${MARK}"
cp "${MARK}" "${SAVED}"
BEFORE="$(sha256sum "${MARK}")"
python3 - "${MARK}" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
data = bytearray(path.read_bytes())
data[0] ^= 1
path.write_bytes(data)
PY
if verify_brand "${FIXTURE}" >"${WORK}/tamper.log" 2>&1; then
  bad "NON-VACUITY: tampered SVG was accepted"
else
  assert_contains "NON-VACUITY: tamper names the SVG" "${WORK}/tamper.log" "mkosi/runtime/brand/ceralive-mark-small-dark.svg: sha256 mismatch"
fi
cp "${SAVED}" "${MARK}"
assert_eq "tamper probe restores exact bytes" "${BEFORE}" "$(sha256sum "${MARK}")"
RESTORE_FILE=""

printf 'orphan\n' >"${FIXTURE}/mkosi/runtime/brand/orphan.svg"
if verify_brand "${FIXTURE}" >"${WORK}/orphan.log" 2>&1; then
  bad "NON-VACUITY: orphan brand file was accepted"
else
  assert_contains "NON-VACUITY: orphan is reported" "${WORK}/orphan.log" "mkosi/runtime/brand/orphan.svg: orphan brand file"
fi
rm "${FIXTURE}/mkosi/runtime/brand/orphan.svg"

RESTORE_FILE="${FIXTURE}/BRAND-ASSETS-NOTICE.md"
cp "${RESTORE_FILE}" "${SAVED}"
BEFORE="$(sha256sum "${RESTORE_FILE}")"
python3 - "${RESTORE_FILE}" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
path.write_text("".join(line for line in path.read_text().splitlines(keepends=True)
                        if line != "- mkosi/runtime/brand/ceralive-mark-small-dark.svg\n"))
PY
if verify_brand "${FIXTURE}" >"${WORK}/notice.log" 2>&1; then
  bad "NON-VACUITY: missing notice entry was accepted"
else
  assert_contains "NON-VACUITY: missing notice entry is reported" "${WORK}/notice.log" "BRAND-ASSETS-NOTICE.md: missing - mkosi/runtime/brand/ceralive-mark-small-dark.svg"
fi
cp "${SAVED}" "${RESTORE_FILE}"
assert_eq "notice probe restores exact bytes" "${BEFORE}" "$(sha256sum "${RESTORE_FILE}")"
RESTORE_FILE=""

printf ' RESULT: %d passed, %d failed\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" -eq 0 ]]
