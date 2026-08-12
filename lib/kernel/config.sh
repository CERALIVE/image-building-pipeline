#!/usr/bin/env bash
#
# kernel/config.sh — input validation and kernel-config-source resolution for
# lib/build-kernel.sh.
#
# Sourced by lib/build-kernel.sh, never executed. Everything here runs BEFORE any
# network, container or disk work, so a half-specified pin fails in the first
# second of the stage rather than half an hour into a `make`.
#
# DYNAMIC SCOPING (the lib/stages/ contract). validate_kernel_source_inputs and
# resolve_kernel_config_mode read — and resolve_kernel_config_mode ASSIGNS —
# variables declared `local` in build-kernel.sh::main(). That is what makes this a
# relocation of main()'s own preamble rather than a rewrite of its data flow: the
# declarations in main() look unused there and must not be "cleaned up".
#
# shellcheck shell=bash
# shellcheck disable=SC2154,SC2034

# ---------------------------------------------------------------------------
# require_kernel_source_field <name> <value>
# ---------------------------------------------------------------------------
require_kernel_source_field() {
  local name="$1" val="$2"
  [[ -n "${val}" ]] \
    || die "kernel_source did not resolve required field '${name}' — refusing to build a kernel from a half-specified pin"
}

# ---------------------------------------------------------------------------
# validate_kernel_source_inputs — every pin the stage cannot proceed without.
#
# Reads from main()'s frame: git_url, commit, patches_url, patches_commit,
# patches_series, builder_image, local_version, kernel_release, package_version,
# dtb_deb_dir, arch, dtb_name, local_patches.
# ---------------------------------------------------------------------------
validate_kernel_source_inputs() {
  require_kernel_source_field git_url "${git_url}"
  require_kernel_source_field commit "${commit}"
  require_kernel_source_field patches_git_url "${patches_url}"
  require_kernel_source_field patches_commit "${patches_commit}"
  require_kernel_source_field patches_series "${patches_series}"
  require_kernel_source_field builder_image "${builder_image}"
  require_kernel_source_field local_version "${local_version}"
  require_kernel_source_field kernel_release "${kernel_release}"
  require_kernel_source_field package_version "${package_version}"
  require_kernel_source_field dtb_deb_dir "${dtb_deb_dir}"
  require_kernel_source_field ARCH "${arch}"
  require_kernel_source_field DTB_NAME "${dtb_name}"

  # A floating patches reference would make the built kernel unreproducible
  # while still LOOKING pinned — the exact failure mode the schema pattern and
  # this assertion exist to make impossible.
  [[ "${commit}" =~ ^[0-9a-f]{40}$ ]] \
    || die "kernel_source.commit must be an exact 40-character SHA (got '${commit}')"
  [[ "${patches_commit}" =~ ^[0-9a-f]{40}$ ]] \
    || die "kernel_source.patches_commit must be an exact 40-character SHA, never a branch or tag (got '${patches_commit}')"

  # Validated here rather than at mount time so a mistyped bench path fails
  # before any container work, like every other input assertion in this block.
  [[ -z "${local_patches}" || ( "${local_patches}" == /* && -d "${local_patches}/.git" ) ]] \
    || die "CERALIVE_KERNEL_PATCHES_LOCAL_REPO must be an absolute path to a git clone (got '${local_patches}')"

  [[ "${arch}" == "arm64" ]] \
    || die "kernel-build-from-source is wired for arm64 only (resolved arch '${arch}'); an x86 family has no kernel_source block and must never reach this stage"
}

# ---------------------------------------------------------------------------
# resolve_kernel_config_mode — decide DEFCONFIG vs CONFIG-FILE mode and resolve
# every repo-local path the chosen mode needs.
#
# The schema already enforces exactly-one-of, but a half-specified config is the
# one mistake that would still BUILD — producing a kernel whose driver set nobody
# chose — so it is re-asserted here rather than trusted.
#
# Reads from main()'s frame: config_git_url, config_commit, config_path,
# defconfig_base, fragment_rel, absent_rel, PIPELINE_DIR.
# ASSIGNS into main()'s frame: config_mode, config_desc, absent_list, and (via
# resolve_defconfig_fragments) fragments_rel_list and fragments.
# ---------------------------------------------------------------------------
resolve_kernel_config_mode() {
  if [[ -n "${config_git_url}${config_commit}${config_path}" ]]; then
    config_mode="config-file"
    require_kernel_source_field config_git_url "${config_git_url}"
    require_kernel_source_field config_commit "${config_commit}"
    require_kernel_source_field config_path "${config_path}"
    [[ -z "${defconfig_base}" && -z "${fragment_rel}" ]] \
      || die "kernel_source declares BOTH config-file mode (config_git_url/config_commit/config_path) and defconfig mode (defconfig_base/defconfig_fragment); exactly one config source may be declared"
    [[ "${config_commit}" =~ ^[0-9a-f]{40}$ ]] \
      || die "kernel_source.config_commit must be an exact 40-character SHA, never a branch or tag (got '${config_commit}')"
    config_desc="${config_path} @ ${config_commit} (${config_git_url})"
    if [[ -n "${absent_rel}" ]]; then
      absent_list="${PIPELINE_DIR}/${absent_rel}"
      [[ -f "${absent_list}" ]] \
        || die "config_absent_symbols list not found: ${absent_list} (kernel_source.config_absent_symbols='${absent_rel}', resolved against ${PIPELINE_DIR})"
      config_desc="${config_desc} [allow-absent: ${absent_rel}]"
    fi
  else
    config_mode="defconfig"
    require_kernel_source_field defconfig_base "${defconfig_base}"
    [[ -z "${absent_rel}" ]] \
      || die "kernel_source.config_absent_symbols is only meaningful in config-file mode; a repo-local defconfig fragment declares exactly what it means and has no upstream-injected symbols to except"
    resolve_defconfig_fragments
    config_desc="${defconfig_base} + ${fragments_rel_list[*]}"
  fi
}

# ---------------------------------------------------------------------------
# resolve_defconfig_fragments — normalise the singular and plural fragment keys
# into ONE ordered list.
#
# `defconfig_fragment` (one path) and `defconfig_fragments` (an ordered list) are
# the same declaration written two ways, and the schema admits exactly one of
# them. Collapsing both here — rather than branching at every consumer — is what
# keeps a single-fragment manifest resolving byte-identically to how it always
# has while a multi-fragment one merges in list order.
#
# Reads from main()'s frame: fragment_rel, fragments_rel, PIPELINE_DIR.
# ASSIGNS into main()'s frame: fragments_rel_list, fragments.
# ---------------------------------------------------------------------------
resolve_defconfig_fragments() {
  [[ -z "${fragment_rel}" || -z "${fragments_rel}" ]] \
    || die "kernel_source declares BOTH defconfig_fragment ('${fragment_rel}') and defconfig_fragments ('${fragments_rel}'); they are the same declaration written two ways, so exactly one may be present"

  local declared="${fragment_rel}${fragments_rel}"
  require_kernel_source_field defconfig_fragment "${declared}"

  # The plural key flattens to a single space-joined param, which is why word
  # splitting is what reconstructs the list — and why a fragment path may not
  # contain whitespace (the schema pattern already forbids it).
  # shellcheck disable=SC2206
  fragments_rel_list=(${declared})

  local rel abs
  for rel in "${fragments_rel_list[@]}"; do
    abs="${PIPELINE_DIR}/${rel}"
    [[ -f "${abs}" ]] \
      || die "defconfig fragment not found: ${abs} (declared in kernel_source.defconfig_fragment(s) as '${rel}', resolved against ${PIPELINE_DIR})"
    fragments+=("${abs}")
  done
}
