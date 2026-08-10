#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 2 ]]; then
	printf 'usage: stage-mkosi-package.sh <archive.deb> <consumer-directory>\n' >&2
	exit 2
fi

archive="$1"
consumer_dir="$2"

[[ -f "${archive}" ]] || {
	printf 'mkosi package archive not found: %s\n' "${archive}" >&2
	exit 1
}

install -d -m 0755 "${consumer_dir}"
install -m 0644 "${archive}" "${consumer_dir}/$(basename "${archive}")"
