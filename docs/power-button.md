# Power button gestures (draft, not board-qualified)

The image ignores a short power-key press at logind. The button service reads
KEY_POWER (116) without grabbing the input device. It offers:

| Gesture | Result |
| --- | --- |
| Tap under 500 ms | Status hook only |
| Two taps, releases at most 400 ms apart | One confirmation, only for an active request |
| Continuous hold for 3 s | Clean `systemctl poweroff`; release before the deadline cancels |
| Hardware hold around 10 s | Existing PMIC behaviour; no registers or firmware changed |

There is **no shorter shutdown path**, including when live. The same full
three-second hold is required in both states. Repeat events do not extend a
hold. Lost events cancel it and require release before rearming. Unplugging the
input device fails the service, so systemd retries discovery. The timer uses a
monotonic clock. Evdev is explicitly switched to CLOCK_MONOTONIC; physical
event timestamps bound the double window even when events are queued. Events
from before request admission cannot confirm a new request. A very late event-loop wake
cancels hold tracking if service observations are more than 250 ms apart and
requires release before rearming. A delayed press starts its hold countdown at
observation time, never in the past. Immediately before shutdown the service
drains all pending batches (bounded to 256 reads), requires a complete decoder
and a positive EVIOCGKEY KEY_POWER state. Read/ioctl uncertainty denies the hold.
The final check is a userspace decision, not an atomic guarantee against a key
release or scheduler pause after that decision.

## logind and dependencies

`manifests/target-release.env` selects Debian 13. Its current systemd package is
[257.13-1~deb13u1](https://packages.debian.org/trixie/systemd), newer than the
251 minimum for `HandlePowerKeyLongPress`. Installation checks the actual image
binary and refuses versions below 251. The drop-in sets `HandlePowerKey=ignore`
and `HandlePowerKeyLongPress=poweroff`.

[systemd v257's source](https://github.com/systemd/systemd/blob/v257/src/login/logind-button.c)
uses a fixed five-second `LONG_PRESS_DURATION`; no logind hold-time option
exists there. The daemon starts a `systemd-inhibit --what=handle-power-key`
child and waits for its post-acquisition readiness before serving. Closing the
child's stdin and waiting for its exit releases ownership without stopping the
confirmation server. If it is absent, logind
still ignores taps and powers off after its own five-second hold, provided the
kernel delivers the hold. No evdev exclusive grab is used. Behaviour across a
service crash or logind restart while a key is down requires a bench check.

The service uses Python's standard library only. `python3` moves from the debug
delta to the shared image list, because minimal Python alone does not supply
all socket modules. Measure image growth and free-slot reserve in the next
image build. This host-only change makes no image-size or boot qualification
claim. Neither CeraUI nor the existing heartbeat LED owner is modified here.

After three consecutive final-hold key-state query errors, the daemon latches
an input-failed state, logs an error, cancels any confirmation and releases its
inhibitor child. It never authorizes another hold or confirmation until an
administrator restarts it after fixing input. A successful query before the
threshold resets the count. Uncertain holds always remain denied. Release the
key, then start a fresh five-second hold for logind's fallback; handing ownership
back does not promise that a press already in progress is replayed. The stock
logind handover and physical shutdown still need both-board qualification.
The host tests exercise synthetic input failures and inhibitor-child lifetime;
they do not emulate or qualify the real logind timer.

## Local client protocol, version 1

Connect to `/run/ceralive-button/control.sock` as root (directory 0700, socket
0600). Do not expose this socket directly to a browser or network. The host
application authenticates/authorizes its caller before opening a request.

- Send `CONFIRM N\n`, an integer timeout of 1–60 seconds. Receive `READY\n`
  before displaying the prompt. Exactly one client may hold a request; another
  receives `BUSY\n` and closes. The owner receives `CONFIRMED\n` or `TIMEOUT\n`,
  then EOF. Disconnect cancels. Each connection may request once; a fresh one
  needs two fresh taps. Both edges of each tap must follow admission. A press
  already down must release before two new taps can qualify. Requests expire
  against current service monotonic time before decoding and again at the final
  confirmation decision; queued on-time taps delivered after expiry yield TIMEOUT.
  These freshness checks preserve version 1 commands and replies.
- `LIVE 1\n` or `LIVE 0\n` gets `OK\n` and EOF. This process-local flag is
  advisory: it cannot enable a shorter shutdown. Clients should republish their
  current state after service restart. Default is false; safety is identical
  in either state. No pairing or reset is performed by this service.
- `STATUS\n` returns `OK\n` or `FAILED INPUT\n`, then EOF. In the failed
  state CONFIRM and LIVE also return `FAILED INPUT\n`; an active confirmation
  receives that failure and closes. Existing clients treat it as unavailable,
  never confirmation. This is an additive version 1 status/failure reply.
- Malformed, pipelined or oversized commands receive `ERROR\n` and close.
  Idle handshakes expire in five seconds. At most 32 clients are admitted.
  Responses are small; disconnected or non-reading clients cannot block holds.

`light_stub(event, remaining)` is the integration hook: `status`, `countdown`
(remaining seconds), `cancel`, `shutdown`, `failed`. It currently logs non-countdown events
and performs no LED writes. The countdown hook is called at approximately 25 ms
intervals. A real light driver must be nonblocking and coordinate with the LED
owner. Do not ship user text promising visible feedback until it is wired.

Discovery accepts exactly one input name `rk805 pwrkey` or `rk806 pwrkey`.
Missing/ambiguous matches fail safely and retry. After measuring the actual
name, an administrator can override ExecStart with `--device /dev/input/...`
on the daemon command. Never assume `event0` numbering is stable.

## Bench check before release

Run separately on **ROCK 5B+** and **Orange Pi 5 Plus**, both without and with
any external power-board supervisor. This implementation cannot change the
supervisor's separate case-button firmware. Leave that path unqualified until
it forwards these gestures without cutting the supply early.

For each configuration record image SHA, systemd version, kernel/DTB, input
name, `/proc/bus/input/devices` entry, stable udev path and measured timings:

- [ ] Identify which `/dev/input/event*` exposes the RK806 power key. Record
  `evtest` KEY_POWER down/up/repeat events and any SYN_DROPPED; confirm discovery.
- [ ] With service stopped, confirm logind receives a held key: tap stays on,
  release before five seconds cancels, continuous hold cleanly powers off.
- [ ] With service running, verify the inhibitor is present; tap shows status
  after the light hook is wired and never shuts down. No duplicate logind action.
- [ ] Measure double-tap acceptance either side of 400 ms, with no client,
  pending client, expired request, disconnect and concurrent clients. Only the
  current owner gets one confirmation; no pairing/reset occurs by itself.
- [ ] Measure release at 0.5, 1, 2.9 s and continuous hold beyond 3 s, idle and
  during a real test stream/recording. Cancelled holds keep the stream alive;
  only the full hold requests a clean shutdown. Record light countdown timing.
- [ ] Test key down across daemon crash/restart and logind restart; confirm no
  accidental tap shutdown and record the fallback deadline.
- [ ] Confirm the hardware long hold still cuts power around its original
  deadline, including when Linux is stuck. Record actual duration; don't infer
  it from the software tests. Use a disposable card and check the next boot.

Host contracts: `bats tests/power-button.bats`; included in default `./run-tests`.
Evdev is synthetic and shutdown/LED callbacks are faked. No host power command
is executed by these tests. Hardware timings above remain unmeasured.
