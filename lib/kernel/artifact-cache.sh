#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2154

kernel_artifact_cache_mode() {
  case "${CERALIVE_KERNEL_ARTIFACT_CACHE:-auto}" in
    auto|0) printf '%s' "${CERALIVE_KERNEL_ARTIFACT_CACHE:-auto}" ;;
    *) die "CERALIVE_KERNEL_ARTIFACT_CACHE must be auto or 0 (got '${CERALIVE_KERNEL_ARTIFACT_CACHE}')" ;;
  esac
}

kernel_artifact_cache_root() {
  printf '%s/%s' "${PIPELINE_DIR}" "${CERALIVE_REL_MKOSI_CACHE_ROOT}/kernel-artifacts"
}

kernel_artifact_cache_key() {
  local file
  {
    printf '%s\0' 'kernel-artifacts-v1' "${git_url}" "${tag}" "${commit}" \
      "${patches_url}" "${patches_commit}" "${patches_series}" \
      "${config_mode}" "${defconfig_base}" "${config_git_url}" \
      "${config_commit}" "${config_path}" "${builder_image}" \
      "${builder_digest}" "${KERNEL_VARIANT:-default}" "${arch}" \
      "${kernel_pkg}" "${kernel_release}" "${local_version}" \
      "${package_version}" "${epoch}" "${dtb_path}"
    for file in "${fragments[@]}"; do
      printf '%s\0' "${file#"${PIPELINE_DIR}/"}"
      sha256sum "${file}" | cut -d' ' -f1
    done
    for file in "${absent_list:-}" \
      "${HERE}/build-kernel.sh" "${KERNEL_LIB_DIR}/config.sh" \
      "${KERNEL_LIB_DIR}/checkout.sh" "${KERNEL_LIB_DIR}/builder.sh" \
      "${KERNEL_LIB_DIR}/package.sh" "${KERNEL_LIB_DIR}/artifact-cache.sh" \
      "${KERNEL_CONFIG_VERIFIER_SH:-${HERE}/verify-kernel-config.sh}" \
      "${KERNEL_BUILDER_DOCKERFILE}"; do
      [[ -n "${file}" ]] || continue
      printf '%s\0' "${file#"${PIPELINE_DIR}/"}"
      sha256sum "${file}" | cut -d' ' -f1
    done
  } | sha256sum | cut -d' ' -f1
}

kernel_artifact_cache_manifest() {
  local dir="$1" deb_name="$2"
  python3 - "${dir}" "${deb_name}" <<'PY'
import hashlib
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
names = [sys.argv[2], 'resolved.config', 'built-modules.txt']
hashes = {name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in names}
(root / 'manifest.json').write_text(json.dumps({'sha256': hashes}, sort_keys=True) + '\n')
PY
}

kernel_artifact_cache_intact() {
  local dir="$1" deb_name="$2"
  python3 - "${dir}" "${deb_name}" <<'PY'
import hashlib
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
names = {sys.argv[2], 'resolved.config', 'built-modules.txt'}
try:
    manifest = json.loads((root / 'manifest.json').read_text())
    hashes = manifest['sha256']
    assert set(manifest) == {'sha256'} and set(hashes) == names
    assert all(isinstance(hashes[name], str) and len(hashes[name]) == 64 and
               hashlib.sha256((root / name).read_bytes()).hexdigest() == hashes[name]
               for name in names)
    assert (root / 'built-modules.txt').stat().st_size > 0
except (OSError, ValueError, KeyError, AssertionError, TypeError):
    sys.exit(1)
PY
}

kernel_artifact_verify_config() {
  local resolved="$1" declared="" expected="" config_tree="" rc=0
  local -a args=(--config "${resolved}")
  if [[ "${config_mode}" == 'defconfig' ]]; then
    if (( ${#fragments[@]} == 1 )); then
      declared="${fragments[0]}"
    else
      expected="$(mktemp)"
      python3 - "${expected}" "${fragments[@]}" <<'PY'
import pathlib
import re
import sys

entries = {}
for path in sys.argv[2:]:
    for line in pathlib.Path(path).read_text().splitlines():
        match = re.match(r'(?:# )?(CONFIG_[A-Za-z0-9_]+)(?:=.*| is not set)$', line)
        if match:
            entries[match.group(1)] = line
pathlib.Path(sys.argv[1]).write_text('\n'.join(entries.values()) + '\n')
PY
      declared="${expected}"
    fi
  else
    config_tree="$(mktemp -d)"
    if ! fetch_pinned_tree "${config_tree}/config" "${config_git_url}" "" "${config_commit}" "config repo"; then
      rm -rf -- "${config_tree}"
      return 1
    fi
    declared="${config_tree}/config/${config_path}"
    if [[ ! -f "${declared}" ]]; then
      rm -rf -- "${config_tree}"
      return 1
    fi
    [[ -z "${absent_list}" ]] || args+=(--allow-absent "${absent_list}")
  fi
  [[ -z "${declared}" ]] || args+=(--declared "${declared}")
  args+=(--required "${PIPELINE_DIR}/manifests/kernel/required-symbols.list")
  if [[ "${KERNEL_VARIANT:-edge}" == 'edge' ]]; then
    args+=(--forbidden "${PIPELINE_DIR}/manifests/kernel/forbidden-symbols.list")
  fi
  bash "${KERNEL_CONFIG_VERIFIER_SH:-${HERE}/verify-kernel-config.sh}" "${args[@]}" || rc=$?
  [[ -z "${expected}" ]] || rm -f -- "${expected}"
  [[ -z "${config_tree}" ]] || rm -rf -- "${config_tree}"
  return "${rc}"
}

kernel_artifact_cache_hit() {
  local key="$1" out="$2" deb_name="$3" root entry rc=0
  root="$(kernel_artifact_cache_root)"
  entry="${root}/${key}"
  [[ -d "${entry}" ]] || return 1
  mkdir -p "${root}/.locks" || return 1
  (
    flock -w 3600 9 || exit 1
    [[ -d "${entry}" ]] || exit 1
    if ! kernel_artifact_cache_intact "${entry}" "${deb_name}" ||
       ! (validate_built_kernel_deb "${entry}/${deb_name}" "${kernel_pkg}" "${package_version}" "${arch}" "${dtb_path}" &&
          kernel_artifact_verify_config "${entry}/resolved.config"); then
      log_warn "kernel artifact cache corrupt ${entry} — rebuilding"
      rm -rf -- "${entry}"
      exit 1
    fi
    "${MKOSI_PACKAGE_STAGING_SH:-${HERE}/stage-mkosi-package.sh}" "${entry}/${deb_name}" "${out}" || exit 1
    install -m 0644 "${entry}/resolved.config" "${out}/resolved.config" || exit 1
    install -m 0644 "${entry}/built-modules.txt" "${out}/built-modules.txt" || exit 1
  ) 9>"${root}/.locks/${key}.lock" || rc=$?
  (( rc == 0 )) || return 1
  log_info "kernel artifact cache HIT ${key}"
}

kernel_artifact_cache_store() {
  local key="$1" deb="$2" built_dir="$3" root entry tmp deb_name
  root="$(kernel_artifact_cache_root)"
  entry="${root}/${key}"
  deb_name="$(basename "${deb}")"
  mkdir -p "${root}/.locks" || return 0
  (
    flock -w 3600 9 || exit 0
    tmp="$(mktemp -d "${root}/.pending.XXXXXXXX")" || exit 0
    if install -m 0644 "${deb}" "${tmp}/${deb_name}" &&
       install -m 0644 "${built_dir}/resolved.config" "${tmp}/resolved.config" &&
       install -m 0644 "${built_dir}/built-modules.txt" "${tmp}/built-modules.txt" &&
       kernel_artifact_cache_manifest "${tmp}" "${deb_name}"; then
      rm -rf -- "${entry}"
      mv -- "${tmp}" "${entry}" || rm -rf -- "${tmp}"
    else
      rm -rf -- "${tmp}"
    fi
  ) 9>"${root}/.locks/${key}.lock" || log_warn "kernel artifact cache store unavailable; built output remains staged"
}
