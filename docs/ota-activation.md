# Staged OS slot activation [PARTIAL]

`activate-installed=false` leaves a successful RAUC OS installation in the other
rootfs without selecting it for the next boot. This image branch installs
`ceralive-rauc-activate.service` at build time and enables it for
`multi-user.target`. Its `Type=oneshot`, `RemainAfterExit=yes` and successful
`ExecStart=/bin/true` leave it active; **its `ExecStop` runs on shutdown**, not
after install. The unit retains systemd's default dependencies, including the
implicit `Conflicts=shutdown.target`. It orders after and wants `rauc.service`,
orders after D-Bus, and requires the boot-state mount (`/boot` on RK3588,
`/boot/efi` on x86) and `/data` for the armed marker. Reverse stop ordering keeps RAUC and those mounts available
until activation completes. It neither starts shutdown nor reboots the device.

The CeraUI orchestrator (a later todo) should use the root-run template interface:

```sh
systemctl start ceralive-rauc-arm@arm.service     # after a successful OS install
systemctl start ceralive-rauc-arm@disarm.service  # cancel activation
systemctl start ceralive-rauc-arm@now.service     # 7-day escalation, at idle
```

The template is not enabled at boot, and the helper accepts only `--arm`,
`--disarm`, and `--now` (plus its no-argument shutdown mode). Calling the helper
directly requires root. `--arm` checks RAUC's detailed slot status before writing
`/data/ceralive/update-state/activation-armed`; a stale/no-pending slot cannot be
armed. Both `--now` and the shutdown hook require that marker, the absence of
`/run/ceralive/streaming`, a two-slot system still booted from its current primary,
and an other-slot installation newer than its last activation. Only then do they
run **`rauc status mark-active other`** and remove the marker on success. If RAUC
fails, the marker remains for another attempt; if streaming is present, shutdown
skips activation and `--now` refuses. `--now` changes only the next boot target;
it does **not** request a reboot. The seven-day timer and notification policy
belong to CeraUI, not this image helper.

The pinned RAUC 1.15.2 retains `activate-installed=false`, which requires manual activation,
and `rauc status mark-active other` as selecting the other slot for the next boot:
[RAUC configuration](https://rauc.readthedocs.io/en/latest/reference.html#activate-installed),
[RAUC activation](https://rauc.readthedocs.io/en/latest/using.html#manually-switch-to-a-different-slot).
The helper parses RAUC's `--detailed --output-format=shell` key/value output
without sourcing it; per-slot installation and activation timestamps establish
whether an inactive rootfs has a newer staged installation. A shared activation
flock prevents two helper calls from racing. The marker directory is on `/data`
so an armed installation survives an ordinary boot; the streaming sentinel and
flock are on `/run` and do not.

The registered `tests/systemd-ordering-cycle.test.sh` gate invokes
`mkosi/runtime/rauc-activation.test.sh`, which stubs RAUC for each
decision path, renders both platform units through the real installer, runs
`systemd-analyze verify`, probes RAUC ordering by closing a deliberate test-only
cycle, and inspects a test systemd manager dump for the implicit shutdown conflict.
No image containing this work has been built or booted yet. The RAUC 1.15.2
source pin resolves the former kernel compatibility decision; this test is not
a hardware shutdown receipt.
