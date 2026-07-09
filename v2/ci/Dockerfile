# CeraLive v2 — canonical mkosi build container (Task 9).
#
# The DEFAULT build path (lib/orchestrate.sh: run_mkosi_build) runs mkosi INSIDE
# this image. A native host mkosi build is opt-in only (--native / MKOSI_NATIVE=1).
#
# WHY a container is the canonical builder:
#   * mkosi 26 (the v2/.mkosi-version pin) needs Python >= 3.12. The TARGET rootfs
#     release (Debian bookworm) ships an older Python and can't run it; an Arch /
#     non-Debian host lacks apt + debian-archive-keyring entirely. One pinned
#     Debian trixie builder gives a reproducible toolchain on any host.
#   * arm64 cross-builds ride the HOST kernel's qemu-user-static binfmt handler
#     (F-flag, kernel-global — see v2/mkosi/mkosi.conf). binfmt-support +
#     qemu-user-static are baked in so the image is self-sufficient and the run
#     stays --privileged-only (no host qemu assumptions).
#
# VERSION PINS — keep in lockstep with v2/.mkosi-version:
#   * mkosi  : v26, installed from the upstream git tag via pipx. (Debian trixie's
#              apt ships only mkosi 25.3, which is older than the pin, so apt is
#              NOT used for mkosi.)
#   * Python : trixie's python3 == 3.13.x, which satisfies mkosi 26's >= 3.12
#              floor. There is no python3.12 package in trixie; 3.13 is the shipped
#              interpreter and is forward-compatible with the 3.12 requirement.
#
# Build (orchestrate.sh does this automatically when the tag is absent):
#   docker build -t ceralive-mkosi-builder:26 -f v2/ci/Dockerfile v2/ci
#   podman build -t ceralive-mkosi-builder:26 -f v2/ci/Dockerfile v2/ci
FROM debian:trixie-slim

# mkosi version pin — MUST match v2/.mkosi-version (26).
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
      reprepro \
      systemd-repart \
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

# Fail the image build LOUDLY if the pin drifts: the builder MUST carry exactly
# mkosi ${MKOSI_VERSION} on a Python that meets the >= 3.12 floor.
RUN mkosi --version \
 && mkosi --version | grep -qx "mkosi ${MKOSI_VERSION}" \
 && python3 --version \
 && python3 -c "import pefile"
