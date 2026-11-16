# Hardware-class policy [EXISTS: resolver and firmware sweep]

`manifests/hardware/module-classes.yaml` is the schema-1 registry. Each class
declares a description, whether it is attachable, module path globs relative to
the kernel module tree, firmware prefixes, and Kconfig symbol names without
`CONFIG_`. `preserved_roots` protects the first component of firmware paths.

A family's `hardware_policy` owns `exclude_module_classes`, `sweep_candidates`
and `sweep_candidate_files`. A board may only declare `include_module_classes`,
and every included class must already be excluded by its referenced family.
Effective exclusions are family exclusions minus board add-backs. General merge
rules remain unchanged: scalars and maps are board-wins, and arrays replace.

`lib/resolve.sh <board>` emits these parameters in its existing sourceable format:

| Parameter | Value |
| --- | --- |
| `FIRMWARE_SWEEP_PREFIXES` | Family sweep candidates followed by effective classes' firmware prefixes, deduplicated in declaration order |
| `FIRMWARE_SWEEP_FILES` | Family sweep candidate files |
| `FIRMWARE_PRESERVED_ROOTS` | Registry preserved roots |
| `HARDWARE_EXCLUDED_MODULE_GLOBS` | Effective classes' module globs, deduplicated |
| `HARDWARE_EXCLUDED_KCONFIG` | Effective classes' Kconfig symbols, deduplicated |

The first three parameters pass through the orchestrator and mkosi into
subimages. The policy map itself is consumed by the resolver and never flattened.
Manifests without a policy retain their existing output.

The validator and resolver share policy checks. Unknown exclusions, attachable
class exclusions, invalid board add-backs, and class prefixes or sweep candidates
under preserved roots fail with the offending key. Class firmware prefixes also
cannot equal, contain or descend into any Bluetooth object or runtime root in
`manifests/rk3588-bluetooth-firmware-roots.txt`. Runtime wildcard prefixes count
as protected roots. In particular, `mrvl/prestera` remains protected by `mrvl/`.
Legacy sweep candidates are exempt from that second restriction: `intel`
continues to depend on the existing build-time consumer proof and Bluetooth
retention checks.

RK3588 excludes the four registered classes. x86 declares no exclusions and
resolves empty sweep/module/Kconfig lists, retaining integrated GPU firmware.
The platform calls `firmware_sweep <root>` after installing firmware packages.
It removes a candidate only when installed modules and built-in driver metadata
have no matching reference, and logs the driver that blocks a deletion.
The proof is all-or-nothing: any unreadable module, incomplete tree walk or
built-in inventory without usable metadata keeps every candidate.
Nested prefixes are independent candidates; preserved roots are rejected before
any deletion, and Bluetooth closure checks remain mandatory. Missing `modinfo`
declines the sweep; an empty family prefix list removes nothing.
The kernel fragment is unchanged. x86 image and hardware qualification remain
separate; future x86 firmware installation belongs in this platform layer with
the sweep called afterwards.

Validate production manifests with `python3 ci/validate-manifests.py`, or a
self-contained fixture manifest tree with
`python3 ci/validate-manifests.py --manifests <directory>`. Schemas always come
from this repository; the selected tree supplies families, boards, registry and
Bluetooth roots. `ADDONS_DIR` continues to select add-on descriptors separately.
Run `bats --jobs 4 tests/manifest-schema.bats` for rejection and resolver cases,
and `./run-tests` for the repository gate.
