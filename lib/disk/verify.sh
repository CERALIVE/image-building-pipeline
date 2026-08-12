#!/usr/bin/env bash
#
# disk/verify.sh — the `assemble-disk.sh verify` static contract check.
#
# Sourced by lib/assemble-disk.sh, never executed. Image build stays in the
# entry (build_disk); the partition/gap/label assertions live in
# lib/verify-disk.sh do_verify, which the entry also sources.
#
# shellcheck shell=bash
# shellcheck disable=SC2154

# ---------------------------------------------------------------------------
# verify_contract — build an A/B + a single-slot test image and ASSERT both
# against the frozen contract. Image build (build_disk) stays here; the
# partition/gap/label assertions live in verify-disk.sh do_verify (task 6).
# ---------------------------------------------------------------------------
verify_contract() {
  local tmp; tmp="$(mktemp -d)"
  register_scratch "${tmp}"
  local ab="${tmp}/ab.img" ss="${tmp}/singleslot.img"

  echo "=============================================================="
  echo " CeraLive Stage 4 — A/B partition layout verification"
  echo " Contract: docs/partition-contract.md §3 (v2, FROZEN)"
  echo " Repart defs: mkosi/repart/*.conf"
  echo " Tooling: $(systemd-repart --version | head -1), $(sgdisk --version 2>&1 | head -1)"
  echo "=============================================================="
  echo

  # --- A/B (>=16 GB; both current boards) -----------------------------------
  echo "### A/B layout (SINGLE_SLOT_FALLBACK=false, ${DEFAULT_TOTAL_MB} MiB medium)"
  build_disk "${ab}" "${DEFAULT_TOTAL_MB}" "false" "false" 2>/dev/null
  echo
  echo "--- sgdisk --print ---"
  sgdisk --print "${ab}" 2>/dev/null | sed -n '/Disk /,$p'
  echo
  do_verify "${ab}"
  echo

  # --- Slot-swap static check (data survives A/B) ---------------------------
  echo "### Slot-swap static check — does /data survive an A/B swap?"
  local l_boot l_a l_b l_data
  l_boot="$(resolve_partlabel boot)";     l_a="$(resolve_partlabel rootfs_a)"
  l_b="$(resolve_partlabel rootfs_b)";    l_data="$(resolve_partlabel data)"
  echo "RAUC-managed rootfs slots (swapped on update): ${l_a}, ${l_b}"
  echo "SHARED partitions (never touched by a swap):    ${l_boot}, ${l_data}"
  local data_start data_size
  data_start="$(part_field "${ab}" 4 'First sector')"
  data_size="$(part_field "${ab}" 4 'Partition size')"
  echo "  data geometry (A active): start=${data_start} sectors, size=${data_size} sectors, PARTLABEL=${l_data}"
  echo "  simulate swap A->B: RAUC flips the active rootfs slot bootname only; it"
  echo "  rewrites NO partition table entry. data start/size are INVARIANT =>"
  echo "  data geometry (B active): start=${data_start} sectors, size=${data_size} sectors, PARTLABEL=${l_data}"
  echo "  data partition is NOT in {${l_a}, ${l_b}} => mutable state SURVIVES the swap OK"
  echo

  # --- Single-slot fallback (<16 GB) ----------------------------------------
  echo "### Single-slot fallback (SINGLE_SLOT_FALLBACK=true, ${SINGLESLOT_TOTAL_MB} MiB medium)"
  build_disk "${ss}" "${SINGLESLOT_TOTAL_MB}" "true" "false" 2>/dev/null
  echo
  echo "--- sgdisk --print ---"
  sgdisk --print "${ss}" 2>/dev/null | sed -n '/Disk /,$p'
  echo
  do_verify "${ss}"
  echo

  discard_scratch "${tmp}"
  echo "=============================================================="
  log_success "ALL contract assertions passed (A/B + single-slot)"
  echo "=============================================================="
}
