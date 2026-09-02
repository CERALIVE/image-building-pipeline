# First-Party `.deb` Producer Suite-Parity Audit

**Status:** `[EXISTS]` — audit captured 2026-09-01 against the release workflows named below.

The image is built on Debian Trixie (`manifests/target-release.env`). This document
records whether every first-party `.deb` producer that enters that image builds
against the same suite and proves that the final ELF does not exceed the device's
glibc floor. It is an evidence inventory, not a claim that a missing assertion is
covered by another repository's image build.

## Posture table

| Producer | Release artifact path | Build-suite declaration | Declared-target-suite gate | GLIBC-floor assertion | Posture |
|---|---|---|---|---|---|
| `cerastream` | `.github/workflows/publish-release.yml:74-112` resolves the suite before the release matrix; the workflow documents why its build must not use the runner userland at `:8-19`. | `ci/cross/target-suite.env:29-33` declares `TARGET_SUITE=trixie` and `GLIBC_FLOOR=2.41`. | Yes: `target-suite.env:3-8` binds the suite, floor, package dependency, and bundled plugin to one declaration. | Yes: the same contract requires `check-glibc-floor.sh` for both shipped ELFs and `libc6 (>= 2.41)`. | **Conformant**. |
| `srt` | `.github/workflows/publish-release.yml:50-72` builds the release `.deb` in `debian:bookworm`; the PR package workflow has the same container at `runtime-package.yml:39-59`. | Fixed Bookworm container. | No target-suite reader or equality assertion in this release path. | No versioned-GLIBC ceiling assertion; the release contract checks linkage only (`publish-release.yml:76-90`). | **Deferred gap**. |
| `CeraUI` | `.github/workflows/publish-release.yml:365-417` builds the `arm64` and `amd64` packages on `ubuntu-latest`. | Runner userland; no Debian suite declaration. | No. | No release-path ELF GLIBC ceiling assertion. | **Deferred gap**. |
| `srtla-send-rs` | `.github/workflows/release.yml:148-227` builds both package arches in `debian:bookworm-slim`. | Fixed Bookworm container (`:152-155`). | No target-suite reader or equality assertion. | Yes for the historical Bookworm floor: `:210-219` rejects imports newer than `GLIBC_2.36`. | **Deferred gap** — the assertion is real but not derived from the Trixie target. |
| `modem-stack` | `.github/workflows/release.yml:284-291` invokes `packaging/ci/build-bookworm.sh` for both arches. | Build script name and repository packaging contract identify Bookworm; no release-workflow target-suite input. | No. | No release-workflow GLIBC import ceiling assertion identified. | **Deferred gap**. |
| `gstlibuvch264src` | `.github/workflows/publish-release.yml:91-137` builds the Docker runtime payload then packages it. | `Dockerfile:4-7` pins a Bookworm-slim digest. | No target-suite reader or equality assertion. | Partial: `publish-release.yml:115-121` rejects `GLIBC_2.38` and `GLIBC_2.39`; it also declares `libc6 (>= 2.36)` at `:132-136`. | **Deferred gap** — a static historical floor, not the device-target floor. |

## What this audit does and does not prove

- A release-path GLIBC check is an ABI ceiling proof for that producer's shipped
  ELF(s); it is not a board-boot proof.
- Building in a fixed Bookworm container may be internally consistent, but it is
  not evidence that the producer follows the image's current Trixie contract.
- The `cerastream` shape is the reference: one target declaration feeds both the
  container and the checked floor, and the package dependency is generated from
  that same value.

## Deferred gap ledger

These are not one-line changes: each producer needs a target-suite input that can
reach its container/build script, a final-artifact GLIBC check, and regression
coverage proving a changed target value reaches both. Track the implementation work
in the owning producer repository; do not duplicate suite constants in this pipeline.

| ID | Owner | Missing contract | Exit criterion |
|---|---|---|---|
| DSP-1 | `srt` | Release package remains fixed to Bookworm without a symbol-version ceiling. | One producer-owned target declaration drives the release container and an ELF GLIBC ceiling check. |
| DSP-2 | `CeraUI` | Debian package builds on the runner with neither declared suite nor ELF floor gate. | Package build runs in the declared target-suite environment and validates every shipped native ELF against its floor. |
| DSP-3 | `srtla-send-rs` | Existing Bookworm/2.36 gate is not tied to the device target. | Container and `GLIBC_*` ceiling derive from one producer-owned target declaration. |
| DSP-4 | `modem-stack` | Differential package builds have no target-suite input or final ELF ceiling gate. | Both architecture builds derive suite/floor from one declaration and inspect all shipped ELF payloads. |
| DSP-5 | `gstlibuvch264src` | Bookworm digest and 2.36/2.39 checks are independent historical literals. | Build base, GLIBC ceiling, and `libc6` floor derive from one target declaration; plugin and bundled `libuvc` are both checked. |

`docs/DEFERRED.md` carries this ledger's lifecycle pointer so this audit does not
look like closed implementation work.
