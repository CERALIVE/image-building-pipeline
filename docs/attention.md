# Shared device attention

Packages report facts; one image consumer selects the highest severity (fatal,
critical, warn, info, then id alphabetically). A condition is not stream status.
Copy should be calm and actionable: a short true line, what to do next, then
technical detail. Never infer that a stream is offline from a component warning.

## Producer contract

Atomically rename a UTF-8 JSON file to `/run/ceralive/attention/<id>.json`:

```json
{"id":"example-storage","severity":"fatal","line":"The card is not ready to use safely.","detail":"The storage check failed.","fix":"Use local recovery to check the card, then restart the device.","led":"auto","expires":1800000000}
```

`id` matches `[a-z][a-z0-9-]{0,63}`, including the filename. Each producer owns
its own id; it must not overwrite another producer. The image owns
`data-readiness`, `temperature-high` and `clock-unset`. `line`, `detail`, `fix`
are required plain text, at most 120/2000/500 characters, with no control
characters. `expires` is Unix seconds, strictly in the future, at most 24 hours
away. Refresh live conditions; remove the file to clear. The optional LED hint
is `auto` (default) or `none`. Invalid, oversized (>8192 bytes), symlinked,
expired and mismatched files are ignored. Use mode 0644 for public conditions.
Only trusted local services may write here; grant narrowly scoped access to
service identities when integrating them. Do not make the directory world writable.

Shell producers can use `/usr/libexec/ceralive/ceralive-attention post ID SEVERITY
LINE DETAIL FIX --ttl 30` and `clear ID`. Other languages can use the same
atomic-file protocol without executing a helper. Temporary filenames must not
end in `.json`. All text is public LAN content: no credentials, identifiers,
raw logs or network configuration. Expiry is wall-clock based; producers must
refresh after a clock correction. A bad clock can expire a condition early.

CeraUI can read `/run/ceralive/attention-status/status.json` (schema:
`conditions` sorted array, `highest` object or null). On the normal TLS front,
GET/HEAD `/attention/` renders the page and `/attention/status.json` exposes the
same conditions. CeraUI display integration is prepared, not implemented here.
The JSON is a snapshot; consumers should apply each condition's expiry.

## Outputs and ownership

The consumer runs without `/data`. Documents are generated in `/run`, escaped
as text, with no scripts, links, forms or write actions. The normal TLS front
serves them when its existing certificate storage works. If storage
readiness fails and the normal backend and setup portal are inactive, a bounded
inetd HTTP handler temporarily uses the normal backend's IPv4 wildcard port 80.
No extra port or IPv6 listener is opened. This fallback exposes `/`, `/attention/` and `/attention/status.json`, GET
and HEAD, with no-store, a strict CSP, five-second connections and eight clients
maximum. Successful readiness stops the socket before application startup.
The daemon never stops a running backend to display a condition. Non-storage
conditions currently use the normal TLS status route, not a competing port 80
listener. LAN availability still requires working network configuration; this
facility does not create a hotspot or change firewall/network policy.

`ceralive-led-status attention <severity|clear>` extends the existing LED
owner. The same sorted discovery and colon-field MMC/power exclusions apply.
It borrows only the first eligible indicator, saves its prior trigger and
returns that trigger when cleared or the consumer stops. Default initialization
still leaves preconfigured triggers alone; brightness is never written. The
kernel's offered `timer` trigger drives these repeating on/off times:

| Severity | On | Off |
| --- | --- | --- |
| info | 0.2 s | 4.8 s |
| warn | 0.5 s | 4.5 s |
| critical | 0.5 s | 0.5 s |
| fatal | 1 s | 3 s |

No timer means no LED override. The ROCK 5B+ DT describes a blue status LED
(`blue:status` in sysfs) with normal `heartbeat`, GPIO0_B7; see the
[board source](https://github.com/torvalds/linux/blob/master/arch/arm64/boot/dts/rockchip/rk3588-rock-5b-plus.dts).
The image DTB agrees on a blue status LED and heartbeat. Physical appearance,
timer availability and HDMI output still require board qualification.

## Console ownership and local login

Critical/fatal conditions own **VT8**, not tty1. The service wants and orders
itself after `getty@tty1.service` and `getty@tty2.service`; those independent
login terminals keep their normal text, font and sessions. The image reserves
VT8 by masking its getty/autovt instances and the attention service conflicts
with those instances. A late login prompt therefore cannot overwrite the message.
There is no diagnostic getty restart and no write to tty1 or tty2.

On first activation the owner saves the foreground VT and VT8's font plus Unicode
map in volatile storage. It changes VT8 to the large 16x32 Terminus font only
when saving the original font succeeded, paints the message and switches to VT8.
The screen says **“Alt+F1 to log in. Alt+F8 returns here.”** tty2 is also available
with Alt+F2. Credentials and login policy are unchanged; no automatic login is
introduced. Serial rescue and SSH keep their existing prerequisites.

The owner repaints VT8 every two-second watch iteration, even if the condition
is unchanged. It switches there only on initial activation: an operator who
chooses a login VT can stay there while the warning remains active. Long detail
is truncated to the console dimensions so the recovery shortcut stays visible;
the read-only page retains full details. This separates durable diagnostic text
from interactive login instead of repeatedly repainting over a live getty.

When the highest condition becomes info/warn, disappears or expires, or the
service stops, the owner first returns to the saved VT (fallback tty1) if VT8
is still foreground. It then clears **only VT8** and restores its exact saved
font. If the operator has already chosen another VT, it leaves that terminal
alone. Even a failed font restore therefore leaves the login visible. The
login prompt was never erased and needs no redraw. Font/return failures retain
the saved state in private `/run/ceralive/attention-console/` for a retry,
including across a manual stop. A failed VT switch leaves the message and login
shortcut visible instead of clearing to a blank screen. Runtime state survives automatic service restarts,
so a restarted owner neither loses the original font nor steals a login session.
Info/warn never acquire a console. There is no effect on reboot, slot health,
stream ownership or the read-only HTTP contract. Physical display/keyboard
availability still requires board qualification.

Console regression tests cover startup repaint, unchanged conditions, operator
VT selection, clear/expiry/stop, restart, font-save/restore failures and bounded
text. `tests/systemd-ordering-cycle.test.sh` probes the actual installed getty
ordering and VT8 masks. The opt-in `tests/attention-vt-vm.test.sh` runs a fresh
RAM-only native x86 Linux guest with real getty/VT devices, no disk or network,
and captures `/dev/vcs1`, `/dev/vcs8` and their geometry before/after hand-back.
Supply a readable kernel with framebuffer support, `CERALIVE_ATTENTION_QEMU`,
`CERALIVE_ATTENTION_VM_KERNEL` and an empty `CERALIVE_ATTENTION_VM_OUTPUT` directory.
`CERALIVE_ATTENTION_QEMU_DATA` selects extracted firmware data if needed;
`CERALIVE_ATTENTION_VM_MODULES` may name matching graphics modules to load **inside
the guest only**. It also checks byte-identical font restoration. Guest evidence
is not HDMI wire evidence or a claim about a board's boot timing.

## Runtime footprint

Python and the console font/loader are shared runtime dependencies; they add
installed files and generated package state. They must fit the unchanged image
reserve gates. The attention service itself never runs APT, downloads packages,
or changes cache policy. A successful fresh-image reserve check does not promise
that a running system still has that reserve after package operations, index
refreshes or logs. Runtime APT lists and binary metadata caches are distinct from
downloaded `.deb` archives and from installed package payload. Budget and measure
them separately; do not attribute all later cache growth to this facility.

## Implemented triggers and prepared hooks

- **Active:** ROCK data readiness (minimum media, partition growth,
  filesystem growth, incomplete filesystem, low space, read-only/unusable data,
  malformed inventory and unexpected command failures). Its numeric-only
  receipt becomes a shared `data-readiness` fatal condition. A failed/timed-out
  service without a receipt gets a generic true failure message. Failed fsck
  and I/O failures that prevent readiness are covered by this generic refusal;
  there is no claim to distinguish their root causes from journals.
- **Active:** any exposed thermal sensor at or above 85 C reports a critical
  high-temperature condition. This advisory neither changes thermal policy nor
  claims throttling or shutdown. It expires after cooling if not refreshed.
- **Active:** a clock before 2025 reports that secure connections may fail.
  It does not establish accurate time or diagnose every TLS failure.
- **Prepared producer hooks only:** `update-rolled-back`, `slot-bad`,
  `boot-loop`, `setup-required`, `setup-network-unavailable`,
  `backend-crash-loop`, `engine-crash-loop`, `modem-unavailable`,
  `sim-unavailable`, `usb-errors`, `power-bank-stand-down`, `fan-stall`.
  Owners must publish actual measured state, with bounded expiry; these are
  documented ids, not fabricated automatic detections. Persisted boot history,
  RAUC state interpretation, engine/service restart windows and setup network
  eligibility belong to those owners. Setup producers should use critical only
  when missing configuration blocks intended use, so HDMI and HTTP show explicit setup instructions; use info/warn
  otherwise. Automatic setup detection and a future passwordless-pairing QR
  remain reserved extensions, not implemented pairing.
  Do not publish pairing tokens through this unauthenticated status interface.

## Boot health and recovery

Attention is advisory and never calls mark-good, mark-bad, rollback or reboot.
Storage readiness still blocks health and update consumers as before. Its
mount is wanted rather than hard-required so the readiness helper executes
and can explain mount failure too. Unsupported root geometry is refused before storage mutation. SSH remains default-off with its existing
persistent identity prerequisites; rescue has no readiness dependency.
Operator reboots spend the existing finite attempts, then use the existing
unconfirmed last-resort head. There is no new rollback loop or false success.
Repair storage and reboot; normal readiness clears its receipt and condition,
stops fallback HTTP, and permits the original healthcheck to assess health.

## Qualification checklist

On disposable media, preserve the original card and recovery route. Capture
baseline slots/counters, enabled SSH, sysfs LED menu, tty1 and network listeners.
Test below-minimum media, refused partition growth, filesystem-old/partition-new,
read-only data, full data and failed mount, plus a readiness timeout. For each,
record the condition JSON, one-second-on/three-second-off blue code, HDMI text,
LAN GET/HEAD and refused POST/path traversal. Confirm no health marker, no reboot,
no refreshed attempts and no update owner. Inject each shared severity and expiry;
verify ranking, no HDMI takeover for warnings and LED hand-back on clear.
Repair, reboot, verify normal port ownership, socket stopped, receipt removed,
condition cleared and health assessed normally. Repeat interrupted growth and
power-cut checks with the ROCK-layout qualification. Restore original media
and compare saved configuration; do not infer hardware success from host mocks.

## Storage cannot start safely (fork topic)

[Español (Latinoamérica)](unsafe-storage.es-419.md).

On the current ROCK image, the minimum is a 16 GB card. The measured floor is
15,000,000,000 bytes, below the measured size of genuine 16 GB cards. The pre-growth check refuses smaller
or read-only media before repartitioning. Failure of that oneshot blocks the
data mount, its filesystem check, automatic filesystem growth and dependent
persistence migration. Migration also requires successful online filesystem
growth before seeding data or enabling the writable application, log and
NetworkManager profile binds. A growfs failure leaves those writers stopped;
the independent readiness/attention path reports the terminal storage failure.
The independent attention service still reaches multi-user boot. It never
marks either slot good, rearms boot attempts or requests a reboot. A later
operator reboot follows the existing finite A/B attempt policy; it is not an
automatic repair loop. Only the supported root geometry is accepted.

The fatal LED code is **one second on, three seconds off** on the first eligible
status indicator. HDMI VT8 and the local HTTP page say “The box can't start
safely”, followed by the cause and fix:

- “This card is too small for the box. Use a card sold as 16 GB or bigger.”
- “The box couldn't prepare its storage.” Use local recovery to check the
  filesystem or set up the card with the image again. If failures persist,
  set up a different card. A metadata read or validation failure does not
  establish that the card has misreported capacity.
- “This card is read-only.” Check the adapter lock; replace a card that stays
  read-only.
- Growth failures say the card could not finish getting ready, with local
  recovery instructions. No automatic repeat, resize or repair is attempted.

The fallback HTTP listener now shares GET/HEAD `/attention/` and
`/attention/status.json` with the normal TLS front, as well as `/` for a browser.
An onboarding client on the local network can probe plain HTTP port 80 at
`/attention/status.json`, inspect `highest.id == "data-readiness"` and
`highest.severity == "fatal"`, and show `line`, `fix` and optional `detail`.
This public status requires no pairing, certificate, application process or
working `/data`. It never accepts credentials or mutations. It preserves the
existing network configuration and never creates an open recovery hotspot.
An inactive readiness unit caused by a failed dependency also gets the page.

All added status writes are volatile `/run` files; no card test file, durable
failure marker or boot-selector write is added. Read-only inventory and
filesystem geometry errors are surfaced. This is **not** a destructive
full-capacity authenticity test: a lying card that returns apparently valid
reads can evade these checks. Do not claim every counterfeit is detected.
A separate first-boot capacity probe needs its own bounded-write and
loader/GPT-preservation qualification.

Host contracts cover refusal before repart, dependency ordering, messages,
LED timing, VT ownership and HTTP routes. Still required before release: on a
spare ROCK card, prove physical LED/HDMI/local-network discovery, small/failed
and read-only storage refusal, no automatic reboot, successful storage recovery
and console login hand-back. No board acceptance follows from host tests.
