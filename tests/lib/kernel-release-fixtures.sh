#!/usr/bin/env bash
# Shared offline kernel-release fixtures. Caller owns WORK and ROOT.
# shellcheck shell=bash
# shellcheck disable=SC2016,SC2154

kernel_test_repo() {
  local dest="$1"
  mkdir -p "${dest}"
  cp -a "${ROOT}/lib" "${ROOT}/manifests" "${ROOT}/ci" "${dest}/"
  cp "${ROOT}/versions.yaml" "${dest}/"
  mkdir -p "${dest}/mkosi/runtime" "${dest}/mkosi/customize"
  cp "${ROOT}/mkosi/runtime/ceralive-kernel-boot-staging.sh" "${dest}/mkosi/runtime/"
  cp "${ROOT}/mkosi/customize/bluetooth-firmware.sh" "${dest}/mkosi/customize/"
  GIT_MASTER=1 git -C "${dest}" init -q
  GIT_MASTER=1 git -C "${dest}" -c user.name=Fixture -c user.email=fixture@example.invalid \
    -c commit.gpgsign=false commit --allow-empty -qm fixture
}

kernel_test_version() {
  python3 - "$1/manifests/families/rk3588.yaml" "$2" <<'PY'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1])
text, count = re.subn(r"(?m)^(\s+package_version:\s*)7\.2\.0-ceralive[0-9]+$",
                      lambda m: m[1] + sys.argv[2], p.read_text())
assert count == 1
p.write_text(text)
PY
}

kernel_test_artifact() (
  umask 022
  local dest="$1" selected="$2" repo="$3" package=linux-image-7.2.0-ceralive-rk3588
  local release=7.2.0-ceralive-rk3588 pkg="${WORK}/release-package"
  rm -rf "${pkg}"
  mkdir -p "${dest}" "${pkg}/DEBIAN" "${pkg}/boot" \
    "${pkg}/usr/lib/linux-image-${release}/rockchip"
  printf 'Package: %s\nVersion: %s\nArchitecture: arm64\nMaintainer: Fixture <fixture@example.invalid>\nDescription: offline APT kernel\n' \
    "${package}" "${selected}" >"${pkg}/DEBIAN/control"
  { head -c 56 /dev/zero; printf 'ARM\x64'; head -c $((5*1024*1024-60)) /dev/zero; } \
    | gzip -nc >"${pkg}/boot/vmlinuz-${release}"
  for dtb in rk3588-rock-5b-plus.dtb rk3588-orangepi-5-plus.dtb; do
    head -c 8192 /dev/zero >"${pkg}/usr/lib/linux-image-${release}/rockchip/${dtb}"
  done
  SOURCE_DATE_EPOCH=1700000000 dpkg-deb --root-owner-group --build "${pkg}" \
    "${dest}/${package}_${selected}_arm64.deb" >/dev/null
  python3 - "${repo}" "${dest}" "${selected}" <<'PY'
import hashlib, json, pathlib, re, sys, yaml
repo, dest = map(pathlib.Path, sys.argv[1:3])
selected = sys.argv[3]
source = yaml.safe_load((repo / 'manifests/families/rk3588.yaml').read_text())['variants']['edge']['kernel_source']
fragment = source['defconfig_fragment']
entries = {}
for path in (repo / fragment, repo / 'manifests/kernel/required-symbols.list'):
    for line in path.read_text().splitlines():
        if line.startswith('#') and not re.fullmatch(r'# CONFIG_\w+ is not set', line):
            continue
        if not line.startswith('# CONFIG_'):
            line = line.split('#', 1)[0].strip()
        match = re.fullmatch(r'(?:# )?(CONFIG_\w+)(?:=.*| is not set)', line)
        if match:
            entries[match[1]] = f'# {match[1]} is not set' if line.endswith('=n') else line
        elif re.fullmatch(r'CONFIG_\w+', line):
            entries.setdefault(line, line + '=y')
(dest / 'resolved.config').write_text('\n'.join(entries.values()) + '\n')
(dest / 'built-modules.txt').write_text('kernel/drivers/bluetooth/btusb.ko\n')
package = 'linux-image-7.2.0-ceralive-rk3588'
deb = dest / f'{package}_{selected}_arm64.deb'
record = dict(package=package, version=selected, arch='arm64',
              kernel_release=package.removeprefix('linux-image-'),
              deb_sha256=hashlib.sha256(deb.read_bytes()).hexdigest(),
              input_fingerprint='0'*64, kernel_epoch=1700000000,
              validated_boards=['orange-pi-5-plus', 'rock-5b-plus'],
              builder_closure=dict(base_image=source['builder_image'],
                  packages=['gcc-aarch64-linux-gnu=14.2 arm64'],
                  compiler='aarch64-linux-gnu-gcc fixture 14.2',
                  dockerfile_sha256=hashlib.sha256((repo/'ci/Dockerfile.kernel').read_bytes()).hexdigest()))
(dest / 'kernel-artifact.json').write_text(json.dumps(record, indent=2, sort_keys=True) + '\n')
PY
  local fingerprint
  fingerprint="$(
    set -a
    eval "$("${repo}/lib/resolve.sh" rock-5b-plus)"
    set +a
    unset KERNEL_VARIANT
    export KERNEL_SOURCE_PACKAGE_VERSION="${selected}"
    bash "${repo}/lib/kernel/released.sh" --board rock-5b-plus \
      --fingerprint-from "${dest}/kernel-artifact.json"
  )" || exit 1
  jq --arg fp "${fingerprint}" '.input_fingerprint = $fp' "${dest}/kernel-artifact.json" >"${dest}/record.tmp"
  mv "${dest}/record.tmp" "${dest}/kernel-artifact.json"
  (cd "${dest}" && sha256sum "${package}_${selected}_arm64.deb" \
    resolved.config built-modules.txt kernel-artifact.json >SHA256SUMS)
)

kernel_test_gh_stub() {
  local bin="$1"
  mkdir -p "${bin}"
  cat >"${bin}/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${KERNEL_TEST_GH_LOG}"
case "$1 $2" in
  'api --paginate') printf '%s\n' "${KERNEL_TEST_TAGS:-}" ;;
  'release download')
    selected="${3#kernel/v}"; shift 3; dest="" names=()
    while (($#)); do
      case "$1" in
        --repo) [[ "$2" == CERALIVE/image-building-pipeline ]]; shift 2 ;;
        --dir) dest="$2"; shift 2 ;;
        --pattern)
          case "$2" in kernel-artifact.json|resolved.config|built-modules.txt|SHA256SUMS) names+=("$2");; *) exit 98;; esac
          shift 2 ;;
        *) exit 99 ;;
      esac
    done
    [[ "${#names[@]}" == 4 && -n "${dest}" ]]
    for name in "${names[@]}"; do cp "${KERNEL_TEST_HISTORY}/${selected}/${name}" "${dest}/${name}"; done ;;
  *) exit 97 ;;
esac
SH
  chmod 755 "${bin}/gh"
}

kernel_test_builder_stub() {
  cat >"$1/docker" <<'PY'
#!/usr/bin/env python3
import os, pathlib, shutil, sys
args = sys.argv[1:]
with open(os.environ['KERNEL_TEST_RUNTIME_LOG'], 'a') as log:
    log.write(' '.join(args) + '\n')
if args[:1] == ['info']:
    print('Offline native fixture')
elif args[:2] == ['image', 'inspect']:
    print('sha256:fixture')
elif args[:1] == ['run']:
    if 'dpkg-query' in args:
        print('gcc-aarch64-linux-gnu=14.2 arm64')
    elif 'aarch64-linux-gnu-gcc' in args:
        print('aarch64-linux-gnu-gcc fixture 14.2')
    else:
        mounts = [args[i+1] for i,a in enumerate(args[:-1]) if a == '-v']
        out = next((pathlib.Path(m.rsplit(':',1)[0]) for m in mounts if m.endswith(':/out')), None)
        if out is None:
            assert any(m.endswith(':/src') for m in mounts), 'unexpected runtime cleanup'
        elif 'KERNEL_EPOCH_ONLY=1' in args:
            (out/'kernel-epoch').write_text('1700000000\n')
        else:
            with open(os.environ['KERNEL_TEST_RUNTIME_LOG'], 'a') as log:
                log.write('COMPILE\n')
            for name in ('linux-image-7.2.0-ceralive-rk3588_7.2.0-ceralive3_arm64.deb',
                         'resolved.config', 'built-modules.txt'):
                shutil.copyfile(pathlib.Path(os.environ['KERNEL_TEST_BUILD_INPUT'])/name, out/name)
else:
    sys.exit('unexpected real-builder boundary: ' + repr(args))
PY
  chmod 755 "$1/docker"
}
