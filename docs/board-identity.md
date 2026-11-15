# Board identity record

Each rootfs slot carries root-owned `/etc/ceralive/release`, mode 0444. The
build forwards the resolved profile's `board_id`, `family` and `capabilities`
as `BOARD_ID`, `FAMILY` and `CAPABILITIES` through mkosi's environment. Both
customization entry points call the same writer. It emits `BOARD`, `FAMILY`
and the quoted space-separated `CAPABILITIES` list alongside `ID=ceralive`.

These are data, never a script to source. Board and family tokens use lowercase
letters, digits, hyphens and underscores. Capability tokens use lowercase
letters, digits and hyphens. Empty capabilities means none. A new board declares
only installed services and physically supported hardware in its own profile;
no architecture-wide inference enables features on future boards.

The current profiles declare the shipped network, modem, update, add-on,
display, Bluetooth, control, audio, fan and encoder services. RK3588 board
profiles also declare `hdmi-rx`; only the ROCK profile declares `b-key-modem`.
The x86 profile declares neither.
`hw-encoder` does not assert live engine health. Peripheral discovery and engine
capability negotiation remain runtime responsibilities.

Older images lack the extra fields; consumers retain their legacy detector for
those images. The record does not qualify a new board's boot, OTA or recovery
support. `tests/board-identity.bats` runs in the default host gate.

The resolver emits an empty `CAPABILITIES` parameter when a profile omits the
field, clearing any inherited build-environment grant.
