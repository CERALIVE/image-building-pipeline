# image-building-pipeline — Agent entrypoint

[Workspace rules](https://github.com/CERALIVE/ceralive/blob/master/AGENTS.md)

<!-- workspace-hard-rules:begin -->
## Workspace hard rules (identical in every CeraLive AGENTS.md)
- Commits and PRs carry the human author only: no Co-authored-by, no AI attribution.
- Start from the updated canonical branch; rebase to update; never `reset --hard` or discard others' work.
- One focused PR per repo, opened against CERALIVE/<repo>; the root policy PR merges first.
- A repo is self-contained: no path above its root; consume @ceralive packages from the registry, never link:/file:.
- Never delete, skip or weaken a test; every behavior change ships with a test.
- A user-visible change updates docs.ceralive.tv in English and Spanish (es-419), and any ceralive.tv claim it touches, in the same release.
- AGENTS.md holds rules and routing only, within budget; contracts and history live in docs/agents/.
- Full canon: https://github.com/CERALIVE/ceralive/blob/master/AGENTS.md
<!-- workspace-hard-rules:end -->


## ROLE
Build standalone CeraLive device images from board/family manifests, pinned packages and kernel sources.
Own rootfs assembly, A/B boot contracts, signed RAUC bundles and feature add-ons.
Reference relocation is documentation-only; it does not qualify hardware or authorize releases.

## STRUCTURE
`lib/` build orchestration and validators; `manifests/` board/family/package contracts.
`mkosi/` image layers and runtime; `ci/` gates and candidate/release tooling.
`tests/` contract suites; `tools/` generators; `fleet/` fleet support; `docs/` engineering reference.

## COMMANDS
PR lint/test jobs in `.github/workflows/v2-ci.yml` (no image build required):
```bash
mapfile -t files < <(git ls-files '**/*.sh' 'build' 'dev-push' 'run-tests')
shellcheck --severity=warning -x "${files[@]}"
ci/check-suite-literals.sh --self-test
ci/check-suite-literals.sh
python3 ci/check-first-party-pins.py
python3 ci/validate-manifests.py
CERALIVE_RUN_REAL_AVAHI_CONTRACT=required CERALIVE_RUN_REAL_RAUC_CONTRACT=required CERALIVE_RUN_REAL_KERNEL_STAGE_CONTRACT=required CERALIVE_RUN_REAL_PRIVILEGE_DROP_CONTRACT=required ./run-tests
```
Python dependencies: `ci/requirements-ci.txt`; tools/provisioning: `v2-ci.yml`.
The kernel-stage contract also needs `CERALIVE_KERNEL_STAGE_ROOTFS`, a pre-exported
native Debian rootfs; see [staging](docs/kernel-staging.md).
Build/boot/release lanes are distinct from the lint/test gate; never claim unrun hardware qualification.

## UPDATE RELEASE BOUNDARY [PARTIAL]
The CeraUI v2026.10.1 pin selects the released unified APT/RAUC orchestrator.
Read [Update Paths](README.md#update-paths--unified-orchestrator-image-qualification-partial)
for the two-board drill scope, origin protection and verified-other-slot mirror rule;
[release process](docs/RELEASE-PROCESS.md) owns verity bundles and signed image channels.
Build caches are reusable state, never candidate, signature or board-proof substitutes.
Multi-uplink failover, full override-free candidate boot and amd64 hardware remain unverified.
Keep [physical bench-label verification](docs/DEFERRED.md) item 12 open without evidence.

## WHERE TO LOOK
| Code path or task | Contract |
|---|---|
| Before changing anything else here, open docs/agents/README.md and read the contract for the subsystem you touch | [Reference index](docs/agents/README.md) |
| Repository scope and legacy context | [Overview (preamble)](docs/agents/overview.md) |
| Role and ownership | [ROLE IN THE GROUP](docs/agents/role-in-the-group.md) |
| Directory layout | [STRUCTURE](docs/agents/structure.md) |
| Subsystem routing and existing runbooks | [WHERE TO LOOK](docs/agents/where-to-look.md) |
| lib/, manifests/, mkosi/, ci/, tests/: build, runtime, boot loadaddr error, bench labels, safety and release contracts | [KEY FACTS](docs/agents/key-facts.md) |
| Feature sysext generation, signing and publishing | [ADD-ON SUBSYSTEM [EXISTS]](docs/agents/add-on-subsystem.md) |
| Reusable kernel boot staging, board-boot.json and root/tar verification [EXISTS] | [Kernel mapping](docs/kernel-build-from-source.md#4-the-dtb-install-mapping) |
| Family kernel-only builds, fingerprints and image-equivalent Bluetooth/UHID firmware checks [EXISTS] | [Kernel-only lane](docs/kernel-build-from-source.md#kernel-only-build-lane-exists) |
| Immutable kernel versions, APT image reuse and signed OS kernel floors [EXISTS] | [Artifact reuse](docs/kernel-build-from-source.md#released-kernel-reuse-exists); [channel publishing](docs/RELEASE-PROCESS.md#signed-channel-publishing-ceraui-os-agent) |
| Immutable kernel candidates and owner-approved single-job KVM release runners [PARTIAL: settings/publication manual] | [Kernel release runbook](docs/kernel-release.md) |
| Kernel activation, boot identity, durable overlays/quarantine and owner-gated capability [PARTIAL] | [Activation lifecycle](docs/ota-activation.md) |
| First-boot WiFi provisioning portal [PARTIAL]: brand mark, lock, notice and fail-soft rendering | [Portal contract](docs/agents/add-on-subsystem.md); [flow and brand refresh](docs/wifi-provisioning.md) |
| Kiosk display and input stack | [KIOSK STACK](docs/agents/kiosk-stack.md) |
| Unsafe build/runtime patterns | [ANTI-PATTERNS](docs/agents/anti-patterns.md) |
| Known issues, deferred work and hardware acceptance limits | [KNOWN ISSUES / DEFERRED](docs/agents/known-issues-deferred.md) |

## HARD RULES
- REPOS case and order are sacred: `("srt" "cerastream" "CeraUI" "srtla" "modem-stack")`; repo-local `versions.yaml` governs fetch provenance.
- gstreamer-rockchip and librga use platform-layer URL+SHA pins; never add them to REPOS or FIRST_PARTY_APT_PKGS.
- `kernel_source.patches_commit` must be an immutable 40-character SHA, never a branch or mutable ref.
- Firmware content, Bluetooth closure, required/forbidden Kconfig and rootfs size gates fail the build; never downgrade them to warnings.
- Each populated ext4 slot must have >= 512 MiB ACTUAL free space; image size alone is not proof of slot reserve.
- The healthcheck is the only mark-good caller for the BOOTED slot; never manually confirm an unverified boot.
- Slot-sync may mark only the OTHER slot good, after verified mirroring of a boot-health-confirmed state; read [the mirror contract](docs/agents/key-facts.md) before editing its receipt or ordering.
- Kernel staging may mark only OTHER eligible after mirror/install/verification; only healthcheck confirms its boot. Read [staging](docs/kernel-staging.md).
- Slot-sync clears its stale mounts before refusing a still-mounted target; only pre-copy repair rc 0/1 permits copying, and the final read-only filesystem check remains mandatory before mark-good.
- Never shadow packaged udev rules with image-owned rules of the same basename; udev resolves ownership by basename.
- Preserve frozen A/B labels, UUID and bootloader contracts; bench PARTLABEL overlays are explicit opt-ins, never production defaults.
- Signed RAUC/add-on trust and immutable release keys are mandatory; never publish unsigned or byte-different replacement artifacts.
- Do not log private keys or credential values; mTLS client keys must remain `_apt`-readable without undoing their numeric ownership.
- One firmware owner: pin archive identity as well as version; an unexplained missing retained-module firmware reference fails closed.
- Never treat DRY_RUN, a clean boot or a test-pattern stream as proof of physical capture, radio or full-image qualification.
- Kernel release runners must use throwaway KVM disks, no host shares/secrets and the workflow-restricted `kernel-release` group; never register a persistent or default-group runner.
