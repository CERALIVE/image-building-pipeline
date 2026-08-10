# CeraLive v2 — canonical mkosi build container (Task 9).
#
# The DEFAULT build path (lib/orchestrate.sh: run_mkosi_build) runs mkosi INSIDE
# this image. A native host mkosi build is opt-in only (--native / MKOSI_NATIVE=1).
#
# WHY a container is the canonical builder:
#   * mkosi 26 (the .mkosi-version pin) needs Python >= 3.12. The TARGET rootfs
#     release (Debian bookworm) ships an older Python and can't run it; an Arch /
#     non-Debian host lacks apt + debian-archive-keyring entirely. One pinned
#     Debian trixie builder gives a reproducible toolchain on any host.
#   * arm64 cross-builds ride the HOST kernel's qemu-user-static binfmt handler
#     (F-flag, kernel-global — see mkosi/mkosi.conf). binfmt-support +
#     qemu-user-static are baked in so the image is self-sufficient and the run
#     stays --privileged-only (no host qemu assumptions).
#
# VERSION PINS — keep in lockstep with .mkosi-version:
#   * mkosi  : v26, installed from the upstream git tag via pipx. (Debian trixie's
#              apt ships only mkosi 25.3, which is older than the pin, so apt is
#              NOT used for mkosi.)
#   * Python : trixie's python3 == 3.13.x, which satisfies mkosi 26's >= 3.12
#              floor. There is no python3.12 package in trixie; 3.13 is the shipped
#              interpreter and is forward-compatible with the 3.12 requirement.
#
# Build (orchestrate.sh does this automatically when the tag is absent):
#   docker build -t ceralive-mkosi-builder:26 -f ci/Dockerfile ci
#   podman build -t ceralive-mkosi-builder:26 -f ci/Dockerfile ci
FROM debian:trixie-20260623-slim@sha256:28de0877c2189802884ccd20f15ee41c203573bd87bb6b883f5f46362d24c5c2

# mkosi version pin — MUST match .mkosi-version (26).
ARG MKOSI_VERSION=26

ENV DEBIAN_FRONTEND=noninteractive \
    PIPX_HOME=/opt/pipx \
    PIPX_BIN_DIR=/usr/local/bin \
    PATH=/usr/local/bin:$PATH

# Build/assembly dependencies. These mirror exactly what lib/orchestrate.sh and
# lib/assemble-disk.sh shell out to, so the containerized build is self-contained:
#   debian-archive-keyring  verify the Debian repos mkosi pulls the rootfs from
#   apt-utils dpkg-dev      apt/dpkg plumbing mkosi and the staging step invoke
#   ca-certificates         HTTPS for apt + the pipx git fetch of mkosi
#   reprepro                local apt repo handling for staged BSP/first-party .debs
#   systemd-repart          Stage-4 disk/partition assembly
#   zstd                    faster bootstrap-time compression; avoids mmdebstrap gzip fallback
#   qemu-user-static        transparent arm64 emulation (binfmt F-flag interpreter)
#   binfmt-support          registers the qemu interpreters
#   pipx git python3        pinned mkosi 26 install from the upstream tag
#   python3-pefile          PE/COFF parsing used by mkosi image assembly
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      -o Dpkg::Options::=--force-unsafe-io \
      debian-archive-keyring \
      apt-utils \
      dpkg-dev \
      ca-certificates \
      file \
      gpg \
      reprepro \
      systemd-repart \
      zstd \
      qemu-user-static \
      binfmt-support \
      pipx \
      git \
      python3 \
      python3-pefile \
 && rm -rf /var/lib/apt/lists/*

# Pin mkosi to the exact upstream tag (trixie apt mkosi is 25.3 — too old for the
# pin). pipx isolates it in its own venv on trixie's python3 (>= 3.12 floor met).
RUN pipx install "git+https://github.com/systemd/mkosi.git@v${MKOSI_VERSION}"

# UPSTREAM FIX — mkosi 26 writes its build-time policy-rc.d NON-EXECUTABLE, so
# invoke-rc.d ignores it and the denial never takes effect.
#
# mkosi/installer/apt.py::Apt.install() drops a `#!/bin/sh\nexit 101\n` helper at
# /usr/sbin/policy-rc.d around every apt transaction and unlinks it afterwards —
# but it creates it under `umask(~0o644)`, i.e. mode 0644. Debian's invoke-rc.d
# gates on `test -x "${POLICYHELPER}"` (init-system-helpers, /usr/sbin/invoke-rc.d
# line 138), so a 0644 helper is not merely ignored, it is reported as ABSENT:
#
#   invoke-rc.d: WARNING: No init system and policy-rc.d missing! Defaulting to block.
#   Reloading system message bus config...Failed to open connection to "system" message bus: …
#   invoke-rc.d: initscript dbus, action "force-reload" failed.
#
# The last one is the damaging shape — a maintainer script that checks
# invoke-rc.d's status cannot distinguish "the chroot has no init" from "this
# package is broken". This repo's own base skeleton tree ships an EXECUTABLE
# helper for exactly that reason (mkosi/mkosi.images/base/mkosi.skeleton), and it
# cannot survive on its own: `Apt.install()` unlinks whatever is at that path when
# its transaction ends.
#
# HONEST SCOPE — this makes the helper mkosi installs actually executable, and it
# is NOT, on its own, sufficient. A real `--variant edge` build with this patch in
# place STILL emits census rows 8/9/21 from the base layer's own
# `‣ Installing Debian` step, which no hook in this repository can reach. Do not
# read this line as "the census rows are fixed"; docs/build-log-census.md carries
# the open analysis under "Rows 8/9/21 — still emitted by a real build".
#
# Scope: BUILD-TIME ONLY. The file is removed before the rootfs is sealed
# (app/mkosi.postinst.chroot::remove_chroot_service_policy, which dies if it
# survives), so nothing about the shipped device changes — this only makes the
# denial that mkosi already intends actually happen.
#
# The `grep -c` assertions are the drift guard: if a future mkosi changes that
# line, the image build FAILS here rather than silently reverting to a build log
# full of warnings nobody reads.
RUN APT_PY="$(python3 -c 'import glob; print(glob.glob("/opt/pipx/venvs/mkosi/lib/python*/site-packages/mkosi/installer/apt.py")[0])')" \
 && test "$(grep -c 'with umask(~0o644):' "${APT_PY}")" = 1 \
 && sed -i 's/with umask(~0o644):/with umask(~0o755):/' "${APT_PY}" \
 && test "$(grep -c 'with umask(~0o644):' "${APT_PY}")" = 0 \
 && test "$(grep -c 'policy-rc.d' "${APT_PY}")" -ge 1 \
 && find /opt/pipx/venvs/mkosi -name '__pycache__' -type d -prune -exec rm -rf {} +

# Fail the image build LOUDLY if the pin drifts: the builder MUST carry exactly
# mkosi ${MKOSI_VERSION} on a Python that meets the >= 3.12 floor.
RUN mkosi --version \
 && mkosi --version | grep -qx "mkosi ${MKOSI_VERSION}" \
 && python3 --version \
 && python3 -c "import pefile"
