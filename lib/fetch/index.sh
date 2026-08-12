#!/usr/bin/env bash
#
# fetch/index.sh — signed apt-index verification, shared by every curl transport.
#
# Both curl fallbacks (Armbian BSP and first-party) walked the same four steps and
# each carried its own copy of the awk that reads a file's SHA-256 out of a
# gpgv-verified Release:
#
#   1. download InRelease
#   2. verify its signature (optionally against a PINNED fingerprint set) and
#      write the verified plaintext Release out
#   3. read the expected SHA-256 of the Packages index out of THAT plaintext
#   4. download the index and hold it to that digest before decompressing
#
# Step 3 is the load-bearing one: read it from the raw InRelease instead of the
# gpgv output and an attacker-prefixed unsigned block is trusted. The single
# reader below always takes the VERIFIED plaintext.
#
# Sourced by lib/fetch-debs.sh; not standalone. The gpgv/sha primitives come from
# lib/fetch-debs-auth.sh, the loggers from common.sh.
#
# ── Optional lookups return a SENTINEL, never `|| true` ─────────────────────
# `index_lookup_optional` exists because `auth_lookup_package` collapses two very
# different outcomes into exit 1: "this package is genuinely not in the index"
# (expected — a cache probe for a package apt has not listed) and "the index is
# missing or empty" (a real fault that used to be swallowed by `|| true`). The
# wrapper separates them: 1 = not found, 2 = the index itself is unusable.
#
# shellcheck shell=bash

INDEX_LOOKUP_NOT_FOUND=1
INDEX_LOOKUP_UNUSABLE=2

# ---------------------------------------------------------------------------
# index_release_digest <verified_release> <path> — echo the SHA-256 the verified
# Release records for <path>. Returns 1 (and echoes nothing) when the file lists
# no such entry, so the caller can name the missing path in its own diagnostic.
#
# The awk tracks the SHA256 block explicitly: any other `Field:` header at column
# one closes it, so an MD5Sum/SHA1 entry for the same path can never be returned
# in its place.
# ---------------------------------------------------------------------------
index_release_digest() {
  local verified_release="$1" path="$2" digest
  [[ -s "${verified_release}" ]] || return 1
  digest="$(awk -v path="${path}" '
    /^SHA256:/ { inside=1; next }
    /^[A-Za-z0-9-]+:/ { inside=0 }
    inside && $3 == path { print $1; exit }
  ' "${verified_release}")"
  [[ -n "${digest}" ]] || return 1
  printf '%s' "${digest}"
}

# ---------------------------------------------------------------------------
# index_verify_digest <file> <expected_sha256> <what> — hold a downloaded index to
# the digest the signed Release named. Logs the mismatch and returns 1; the caller
# decides whether that is fatal.
# ---------------------------------------------------------------------------
index_verify_digest() {
  local file="$1" expected="$2" what="$3" actual
  actual="$(sha256sum "${file}" | awk '{print $1}')"
  if [[ "${actual}" != "${expected}" ]]; then
    log_error "${what} checksum mismatch: expected ${expected}, got ${actual}"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# index_lookup_optional <index> <pkg> <version> <arch> — a lookup whose MISS is a
# legitimate outcome (the verified-cache probe). Echoes the resolved row on a hit.
#
#   0                        hit; the tab-separated row is on stdout
#   $INDEX_LOOKUP_NOT_FOUND  no such package/version/arch in this index
#   $INDEX_LOOKUP_UNUSABLE   the index path is empty, absent or unreadable —
#                            a real fault, logged, never silently treated as a miss
# ---------------------------------------------------------------------------
index_lookup_optional() {
  local index="$1" pkg="$2" version="$3" arch="$4" row
  if [[ -z "${index}" ]]; then
    log_error "index lookup for ${pkg}: no index path was supplied"
    return "${INDEX_LOOKUP_UNUSABLE}"
  fi
  if [[ ! -s "${index}" ]]; then
    log_error "index lookup for ${pkg}: index is missing or empty: ${index}"
    return "${INDEX_LOOKUP_UNUSABLE}"
  fi
  row="$(auth_lookup_package "${index}" "${pkg}" "${version}" "${arch}")" \
    || return "${INDEX_LOOKUP_NOT_FOUND}"
  printf '%s' "${row}"
}

# ---------------------------------------------------------------------------
# index_decompress_gz <src.gz> <dest> — decompress a verified index. Kept here so
# both transports name one verb; `gzip -dc >` rather than `gzip -df` so the
# verified `.gz` survives for a caller that wants to re-hash it.
# ---------------------------------------------------------------------------
index_decompress_gz() {
  local src="$1" dest="$2"
  gzip -dc "${src}" >"${dest}"
}
