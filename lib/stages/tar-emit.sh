#!/usr/bin/env bash
#
# stages/tar-emit.sh — orchestrator stage [6/9]: emit the normalized rootfs tar.
#
# The tar is the parity artifact and is ALWAYS produced; it is also the subject of
# [6b/9] and [6c/9], which is why they run against it rather than the mkosi tree.
#
# Sourced by lib/orchestrate.sh. See stages/resolve.sh for the dynamic-scoping
# contract every stage module relies on.
#
# shellcheck shell=bash
# shellcheck disable=SC2154,SC2034

# ---------------------------------------------------------------------------
# stage_tar_emit — [6/9]
#
# Reads from main()'s frame: board, ts, rootfs_tree.
# Writes into main()'s frame: out_dir, artifact.
# ---------------------------------------------------------------------------
stage_tar_emit() {
  log_info "[6/9] emitting normalized artifact images/${board}/${ts}.rootfs.tar"
  out_dir="${IMAGES_DIR}/${board}"
  mkdir -p "${out_dir}"
  artifact="${out_dir}/${ts}.rootfs.tar"
  emit_artifact "${rootfs_tree}" "${artifact}"
  log_success "artifact: ${artifact} ($(du -h "${artifact}" | cut -f1)), sha256 in ${artifact}.sha256"
}

# ---------------------------------------------------------------------------
# emit_artifact <rootfs_tree> <artifact.tar>
# Produce a normalized, deterministic tarball + sha256. Runs in the builder
# container when the tree is root-owned and the host can't read/tar it.
# ---------------------------------------------------------------------------
emit_artifact() {
  local tree="$1" artifact="$2"
  # Deterministic ordering + owner + clamped mtime so the same tree always tars
  # to the same bytes (task 14). --sort=name pins entry order; gnu format avoids
  # the per-file pax atime/ctime headers that would re-introduce wall-clock drift.
  local -a tar_repro=(
    --sort=name --numeric-owner --owner=0 --group=0
    --mtime="@${SOURCE_DATE_EPOCH:-0}" --format=gnu
  )
  if tar -C "${tree}" "${tar_repro[@]}" -cf "${artifact}" . 2>/dev/null; then
    :
  else
    log_info "rootfs is root-owned — tarring inside the builder container"
    local runtime="docker"; command -v docker >/dev/null 2>&1 || runtime="podman"
    "${runtime}" run --rm \
      -e "SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-0}" \
      -v "${MKOSI_DIR}:/work" -v "$(dirname "${artifact}")":/out \
      "${MKOSI_BUILDER_IMAGE}" \
      tar -C "/work/build/app" "${tar_repro[@]}" -cf "/out/$(basename "${artifact}")" .
  fi
  ( cd "$(dirname "${artifact}")" && sha256sum "$(basename "${artifact}")" >"$(basename "${artifact}").sha256" )
}
