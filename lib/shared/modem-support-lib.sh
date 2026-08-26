#!/usr/bin/env bash
#
# modem-support-lib.sh — the ONE reader/checker for modem-support file ownership
# and for udev rule-file BASENAME shadowing.
#
# Two properties live here, and both are invisible to `dpkg -S`:
#
#   1. BASENAME SHADOWING. udev resolves rules by BASENAME across its whole
#      directory search path, and /etc/udev/rules.d wins over
#      /usr/lib/udev/rules.d and /lib/udev/rules.d. An image-generated /etc file
#      that happens to share a basename with a PACKAGED rules file therefore
#      replaces it completely — while `dpkg -S` on the packaged path keeps naming
#      the package, and `dpkg --verify` keeps passing, because the packaged file
#      is still there and still intact. It is simply never read. Nothing in the
#      package manager can observe this, so it has to be observed here.
#
#   2. UNIQUE OWNERSHIP. Every modem-support file in the emitted rootfs must be
#      owned by EXACTLY ONE producer: a packaged path by exactly one .deb, an
#      image-generated path by none. Two packages claiming one path is a
#      last-unpack-wins race; a packaged path claimed by nobody is an orphan the
#      next `apt-get upgrade` will not manage.
#
# Profile-neutral by construction (docs/shell-profiles.md): sets no shell option,
# installs no trap and sources nothing, so the build-strict [7/9] parity gate and
# the contract-test harnesses can both consume it unchanged.
#
# shellcheck shell=bash

# udev's directory search path, rootfs-relative. Order is precedence: the FIRST
# entry is the admin tier that shadows every later one.
MODEM_SUPPORT_UDEV_ADMIN_DIR="etc/udev/rules.d"
MODEM_SUPPORT_UDEV_PACKAGED_DIRS=("usr/lib/udev/rules.d" "lib/udev/rules.d")

# The closed owner vocabulary of manifests/modem-support-ownership.txt.
MODEM_SUPPORT_OWNER_PACKAGE="ceralive-modem-support"
MODEM_SUPPORT_OWNER_IMAGE="image"

# ---------------------------------------------------------------------------
# modem_support_ledger_rows <ledger> — echo `owner<TAB>path` for every declared
# row, comments and blank lines stripped. Exits non-zero only if the file is
# unreadable; an empty ledger is a caller decision, not an error here.
# ---------------------------------------------------------------------------
modem_support_ledger_rows() {
  local ledger="$1"
  [[ -r "${ledger}" ]] || return 1
  sed -e 's/[[:space:]]*#.*$//' "${ledger}" | awk 'NF >= 2 { printf "%s\t%s\n", $1, $2 }'
}

# ---------------------------------------------------------------------------
# modem_support_ledger_violations <ledger> — echo one diagnostic per structural
# defect in the ledger itself; return 1 when any was echoed.
#
# The prefix rules are the whole point rather than tidiness: a PACKAGED file
# under /etc/ would be a dpkg conffile the image could silently diverge from, and
# an IMAGE file outside /etc/ would sit in the packaged tier where the next
# package upgrade overwrites or orphans it.
# ---------------------------------------------------------------------------
modem_support_ledger_violations() {
  local ledger="$1" owner path row found=0
  local -A seen=()

  if ! modem_support_ledger_rows "${ledger}" >/dev/null 2>&1; then
    printf 'ledger unreadable: %s\n' "${ledger}"
    return 1
  fi

  while IFS=$'\t' read -r owner path; do
    [[ -n "${owner}" && -n "${path}" ]] || continue
    row="${owner} ${path}"
    case "${owner}" in
      "${MODEM_SUPPORT_OWNER_PACKAGE}")
        if [[ "${path}" == /etc/* ]]; then
          printf 'packaged path in the admin tier (would become a shadowable conffile): %s\n' "${row}"
          found=1
        fi
        ;;
      "${MODEM_SUPPORT_OWNER_IMAGE}")
        if [[ "${path}" != /etc/* ]]; then
          printf 'image-generated path outside the admin tier (a package upgrade would clobber it): %s\n' "${row}"
          found=1
        fi
        ;;
      *)
        printf 'unknown owner (expected %s or %s): %s\n' \
          "${MODEM_SUPPORT_OWNER_PACKAGE}" "${MODEM_SUPPORT_OWNER_IMAGE}" "${row}"
        found=1
        continue
        ;;
    esac
    if [[ "${path}" != /* ]]; then
      printf 'ledger path is not absolute: %s\n' "${row}"
      found=1
    fi
    if [[ -n "${seen[${path}]:-}" ]]; then
      printf 'DOUBLE OWNERSHIP — %s is claimed by both %s and %s\n' \
        "${path}" "${seen[${path}]}" "${owner}"
      found=1
    else
      seen["${path}"]="${owner}"
    fi
  done < <(modem_support_ledger_rows "${ledger}")

  (( found == 0 ))
}

# ---------------------------------------------------------------------------
# udev_shadow_scan <admin-dir> <packaged-dir…> — echo one `basename<TAB>admin
# path<TAB>packaged path` line per shadowed rules file; return 1 when any was
# echoed. Directory-shaped rather than rootfs-shaped so a fixture tree can drive
# exactly this code, which is what proves the check is not vacuous.
# ---------------------------------------------------------------------------
udev_shadow_scan() {
  local admin_dir="$1"; shift
  local packaged_dirs=("$@")
  local admin_file base packaged_dir candidate found=0

  [[ -d "${admin_dir}" ]] || return 0

  # Read the listing through a command substitution, never a pipe into a reader
  # that can exit early: `find … | grep -q` SIGPIPEs find, and under pipefail a
  # correct scan then reports failure (this repo has shipped that bug four times).
  local listing
  listing="$(find "${admin_dir}" -maxdepth 1 -type f -name '*.rules' -print 2>/dev/null | sort)"
  [[ -n "${listing}" ]] || return 0

  while IFS= read -r admin_file; do
    [[ -n "${admin_file}" ]] || continue
    base="${admin_file##*/}"
    for packaged_dir in "${packaged_dirs[@]}"; do
      candidate="${packaged_dir}/${base}"
      # A symlink from the admin tier to the packaged file is the sanctioned way
      # to pin precedence deliberately; only a real, independent file shadows.
      if [[ -f "${candidate}" && ! -L "${admin_file}" ]]; then
        printf '%s\t%s\t%s\n' "${base}" "${admin_file}" "${candidate}"
        found=1
      fi
    done
  done <<<"${listing}"

  (( found == 0 ))
}

# ---------------------------------------------------------------------------
# udev_shadow_scan_rootfs <rootfs> — udev_shadow_scan over an emitted rootfs.
# ---------------------------------------------------------------------------
udev_shadow_scan_rootfs() {
  local root="${1%/}"
  local -a packaged=()
  local d
  for d in "${MODEM_SUPPORT_UDEV_PACKAGED_DIRS[@]}"; do
    packaged+=("${root}/${d}")
  done
  udev_shadow_scan "${root}/${MODEM_SUPPORT_UDEV_ADMIN_DIR}" "${packaged[@]}"
}

# ---------------------------------------------------------------------------
# rootfs_path_owners <rootfs> <path> — echo every installed package whose dpkg
# file list claims <path>, one per line. Reads /var/lib/dpkg/info/*.list
# directly: the build host may be Arch, so `dpkg -S` is not available and the
# subject is a rootfs TREE rather than the host's own dpkg database.
# ---------------------------------------------------------------------------
rootfs_path_owners() {
  local root="${1%/}" path="$2" listfile pkg
  local info="${root}/var/lib/dpkg/info"
  [[ -d "${info}" ]] || return 0
  local listing
  listing="$(find "${info}" -maxdepth 1 -type f -name '*.list' -print 2>/dev/null | sort)"
  [[ -n "${listing}" ]] || return 0
  while IFS= read -r listfile; do
    [[ -n "${listfile}" ]] || continue
    if grep -qxF "${path}" "${listfile}"; then
      pkg="${listfile##*/}"
      pkg="${pkg%.list}"
      printf '%s\n' "${pkg%%:*}"
    fi
  done <<<"${listing}"
}

# ---------------------------------------------------------------------------
# modem_support_ownership_violations <rootfs> <ledger> — echo one diagnostic per
# ownership defect in an emitted rootfs; return 1 when any was echoed.
#
# A ledger path that is ABSENT from the rootfs is not judged here: the board-gated
# slot-UID rules legitimately do not exist while `modem_ports.status` is
# unverified, and an offline/dev build stages no first-party .deb at all. The
# check is about who owns what is THERE.
# ---------------------------------------------------------------------------
modem_support_ownership_violations() {
  local root="${1%/}" ledger="$2" owner path owners count found=0

  while IFS=$'\t' read -r owner path; do
    [[ -n "${owner}" && -n "${path}" ]] || continue
    [[ -e "${root}${path}" ]] || continue
    owners="$(rootfs_path_owners "${root}" "${path}")"
    count="$(grep -c . <<<"${owners}")"
    [[ -n "${owners}" ]] || count=0
    case "${owner}" in
      "${MODEM_SUPPORT_OWNER_PACKAGE}")
        if (( count == 0 )); then
          printf 'ORPHAN — %s is present but owned by no package (declared %s)\n' "${path}" "${owner}"
          found=1
        elif (( count > 1 )); then
          printf 'DOUBLE OWNERSHIP — %s is claimed by %d packages: %s\n' \
            "${path}" "${count}" "$(tr '\n' ' ' <<<"${owners}")"
          found=1
        elif [[ "${owners}" != "${MODEM_SUPPORT_OWNER_PACKAGE}" ]]; then
          printf 'WRONG OWNER — %s is owned by %s, expected %s\n' \
            "${path}" "${owners}" "${MODEM_SUPPORT_OWNER_PACKAGE}"
          found=1
        fi
        ;;
      "${MODEM_SUPPORT_OWNER_IMAGE}")
        if (( count > 0 )); then
          printf 'DOUBLE OWNERSHIP — image-generated %s is also claimed by: %s\n' \
            "${path}" "$(tr '\n' ' ' <<<"${owners}")"
          found=1
        fi
        ;;
    esac
  done < <(modem_support_ledger_rows "${ledger}")

  (( found == 0 ))
}
