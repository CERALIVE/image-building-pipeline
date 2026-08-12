# Shell profiles

Every bash file in this repository belongs to exactly one of **three** profiles.
The profiles are not style preferences — each one exists because the other two
would produce a wrong outcome in that context, and every profile boundary here
was drawn from a real defect.

The census that produced them (185 tracked bash files at the time of writing):

| `set` line | Count | Profile |
|---|---:|---|
| `set -euo pipefail` (+ `set -Eeuo pipefail`) | 111 | build-strict |
| `set -uo pipefail`, `mkosi/runtime/*` | 3 | device-daemon |
| `set -uo pipefail`, test harnesses | 12 | contract-test |
| none — sourced fragments and chroot modules | 59 | inherits its sourcer's profile |

---

## 1. `build-strict` — host-side build and orchestration

**Shape**

```bash
source "${HERE}/lib/common.sh"   # set -euo pipefail + trap err_trap ERR + loggers
```

**Who** — `build`, `run-tests`, `dev-push`, `dev-sync`, everything under `lib/`,
`ci/`, and the mkosi customize helpers that run on the build host.

**Why `-e` plus an ERR trap.** v1's root cause of unreliability was silent
`apt`/`dpkg` failure (`customize-image.sh:170-174,231-232`): a command failed, the
script continued, and the defect surfaced as a subtly broken image hours later.
`lib/common.sh` therefore converts ANY unguarded non-zero command into an
immediate exit that names `file:line` and the failing command. The corollary is
written into that file's header and is part of this profile: **no `|| true`**.
A `|| true` resets the exit status to 0 *before* the trap can see it, which
defeats the whole mechanism. The one sanctioned "this command does not run now"
is the explicit `DRY_RUN` plan path, which LOGS the command and returns 0
deliberately.

**`-E`** (`ci/check-build-log.sh`) is the same profile with the ERR trap
inherited into functions and subshells; use it when the failing command can be
inside a function called from a command substitution.

**Logging** — `log_info` / `log_warn` / `log_error` / `log_success` from
`lib/shared/log-lib.sh`, which `common.sh` sources.

---

## 2. `device-daemon` — long-lived scripts that run ON the board

**Shape**

```bash
set -uo pipefail                 # note: NO -e
# self-contained log() / die() — the repo's lib/ is not mounted here
```

**Who** — `mkosi/runtime/ceralive-healthcheck.sh`,
`mkosi/runtime/ceralive-provision.sh`, `mkosi/runtime/ceralive-portal.sh`, and
by extension the `mkosi/customize/postinst.d/*` modules, which carry
`declare -F`-guarded `log()`/`die()` fallbacks for exactly this reason.

**Why no `-e`.** These scripts are the device's own recovery machinery. The
healthcheck decides whether a freshly-installed RAUC slot is marked good; the
provisioning portal is the only way back into a headless board with no WiFi
credentials. A profile that aborts on the first non-zero command turns a probe
that legitimately fails — an unreachable host, a `systemctl is-active` on a unit
that is not installed, a sysfs attribute a board does not have — into a dead
device. Every one of these scripts must reach its own decision point and exit
with a status it chose.

**Why self-contained logging.** They execute inside mkosi SUBIMAGE CHROOTS and,
later, on the device, where `lib/` does not exist. A module may never assume
anything else has been sourced. This is the same rule the postinst split
records: every module defines its own guarded `log`/`die`.

**Fail-soft, but never fail-silent.** "No `-e`" is not "ignore errors". The
established pattern in these scripts is: poll to a *deadline* rather than sleep a
constant, treat an absent hardware shape as an informational no-op and exit 0,
treat a rejected write as a warning, and treat a write the kernel ACCEPTED and
then did not honour as **fatal** — because by then the hardware was proven
present.

---

## 3. `contract-test` — collecting test harnesses

**Shape**

```bash
set -uo pipefail                 # note: NO -e
source "<repo>/tests/lib/assertions.sh"
...
printf ' RESULT: %d passed, %d failed\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" -eq 0 ]]            # the harness owns its exit code
```

**Who** — the `.test.sh` / `.sh` harnesses under `tests/` and the two platform
proofs `mkosi/platform/{boot/test-fallback.sh,x86/test-x86-fallback.sh}`.
`.bats` suites are a fourth thing and are governed by bats itself, not by a
`set` line.

**Why no `-e`.** A harness must run every assertion and report all of them. Under
`-e` the first failed assertion aborts the run, so a change that breaks fifteen
contracts is reported as one, and the next iteration re-discovers the other
fourteen one at a time. `tests/rauc-rollback.sh` states this in its own header:
it *collects* failures and owns its exit code.

**Assertions come from `tests/lib/assertions.sh`** — `PASS`/`FAIL`, `ok`, `bad`,
`assert_eq`, `assert_contains`. Its output format is a contract, not styling:
these transcripts are captured as evidence and compared across runs.

**Non-vacuity is part of the profile.** A test that can pass while measuring
nothing is worse than no test. Every guard here carries an inverse leg — the
mutation that *should* fail actually fails. Concretely: a static test that reads
a library by TEXT must read the whole module SET (pointed at a thin entry it
extracts nothing and passes vacuously), and it must build that set into a FILE
before grepping, because piping it into `grep -q` SIGPIPEs the writer and
`pipefail` turns a correct read into a failure.

---

## Choosing a profile

| Question | Answer |
|---|---|
| Does it run on the build host as part of producing an image? | **build-strict** |
| Does it ship in the image and run on the board? | **device-daemon** |
| Is it a harness whose job is to report every violation? | **contract-test** |
| Is it a `.sh` fragment that is only ever `source`d? | none of its own — it inherits its sourcer's, and must define `declare -F`-guarded `log`/`die` fallbacks if it can be sourced inside a chroot |

## Shared pieces, and what they deliberately are not

| File | Profile-neutral because |
|---|---|
| `lib/shared/log-lib.sh` | sets no shell options and installs no trap, so any profile can have the `[LEVEL] HH:MM:SS message` format without inheriting strict mode |
| `lib/shared/args-lib.sh` | same; supplies `args_expand_inline` (`--opt=value` splitting), `args_usage_die`, `args_is_help`, `args_has_flag` to the entry points, and deliberately does NOT own their option sets — `--variant` means nothing to `dev-sync` and `--frontend` means nothing to `build` |
| `tests/lib/assertions.sh` | contract-test only, and says so; it is the one place `ok`/`bad`/`assert_eq`/`assert_contains` are defined |
