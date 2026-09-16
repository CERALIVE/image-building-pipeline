# First-party pin currency [EXISTS]

An internally consistent image can still downgrade a board. On 2026-09-15,
the image selected cerastream `2026.9.2` while `2026.9.3` was released and had
been installed through APT. Reflashing restored the stale-format capture
preflight bug. The Rockchip plugin had the same release-versus-pin gap.

## Run the guard

```sh
python3 ci/check-first-party-pins.py
tests/first-party-pin-currency.test.sh -v
```

Requirements: Python 3.12+, Bash and `dpkg` (comparison only; nothing is
installed). The offline tests also use the existing CI dependency PyYAML.
Exit codes: **0** current or explicitly overridden; **1** stale pins;
**2** unverifiable evidence, malformed input, or inconsistent manifests.
Forward versions pass this currency check; existing authenticated package-fetch
and checksum gates still determine whether those exact artifacts exist.

The `v2 Pipeline CI` shellcheck job runs the guard before downstream jobs.
The registered unit suite executes the real CLI and each workflow's actual
guard command against both current and deliberately downgraded fixture trees.
The release candidate and scheduled real-build workflows also check currency
before building, using a tighter evidence-age bound.

## What is authoritative

| Input | What the guard measures |
|---|---|
| `lib/fetch-debs.sh` `FIRST_PARTY_APT_PKGS` | Exact app-package coverage; an added/unmapped or removed package fails closed |
| `manifests/first-party-deb-versions.txt` | Effective exact pin on **each** architecture; arch-specific rows override generic rows as in the fetcher |
| `versions.yaml` | Component provenance, read through `get_pin`; it must agree with selected component package versions |
| `manifests/rk3588-userspace-deb-versions.txt` | Active first-party platform filename version and decoded GitHub URL tag; commented predecessors do not count |
| `manifests/first-party-releases.json` | Independently observed published stable release and package versions, not copied from image pins |

Covered components: `srt`, `cerastream`, `CeraUI`, `srtla-send-rs`,
`gstlibuvcsrc`, `modem-stack`, `gstreamer-rockchip`, and `librga`.
The modem companion follows its release tag; its nine upstream-versioned
packages are compared individually against the release's package manifest.
Their per-source rebuild counters are **not** inferred from the component tag.
GitHub sanitizes `~` in their asset names, so the release manifest—not the
asset filename—supplies those Debian versions.

Cloud/receiver-only entries in `versions.yaml`, third-party MPP and multimedia
config, and source-commit kernel inputs are not first-party device package
release pins. They keep their existing gates. Neither platform library moves
into `REPOS` or the app layer. `librga-ceralive-dev` is not an image package.

Version comparison uses Debian's numeric comparator after removing an optional
`v`/`srt-v` prefix and recognized hash/timestamp build suffixes. In particular,
`+ceralive.10` is **newer** than `+ceralive.9`; that suffix is never discarded
as SemVer build metadata. Unknown version schemes fail closed.

## Release evidence and network policy

CI deliberately uses a **committed catalog**, not a live GitHub request.
The ordinary PR token cannot read private sibling repositories such as
cerastream, and an anonymous 404 is not proof that a newer release is absent.
This keeps PR checks deterministic within an explicitly bounded observation
window and avoids exposing a cross-repository credential to PR code.

Refresh using a local `gh` login with read access to **all eight** repositories:

```sh
python3 ci/check-first-party-pins.py --refresh
```

The refresh enumerates all release pages, excludes drafts/prereleases and
binding-only release trains, and picks the greatest component version, not
GitHub's manually selected `latest` flag or a lexicographic tag maximum.
It requires the selected newest release to carry all image packages. It
never falls back to an older complete release if the newest is incomplete.
It updates only the catalog, **never the three pin inputs or overrides**.
If pins are stale, a successful catalog refresh still exits **1** after
writing the new evidence; this is the expected signal to review the pins.

Each GitHub command has a 60-second timeout and at most three attempts. Missing
credentials, API/rate-limit errors, malformed responses and incomplete releases
fail closed; a failed discovery leaves the previous catalog untouched. Review
and commit the refreshed catalog in a normal PR. Do not hand-edit release
versions or restamp `checked_at` without re-querying the release sources.

**Freshness bounds:** ordinary CI allows at most **168 hours (seven days)**;
release candidates and scheduled real builds allow **24 hours**. Future-dated
or expired evidence fails, including with a rollback override. Maintain the
catalog with every first-party release and at least weekly; refresh within a
day before a real CI image build. There is no automatic refresh bot or new
secret in this change. A stale catalog requires a reviewed refresh, not a
warning-only bypass.

**Limit:** a release published after `checked_at` is invisible until refresh,
up to the bounds above. The printed timestamp is the scope of the verdict;
the output never calls a snapshot check a live lookup. This is the deliberate
availability/currency trade-off of the committed-manifest option, not a claim
to catch APT changes or new releases instantaneously. For the freshest manual
pre-build check, run `--refresh --max-age-hours 24` immediately before `./build`.
Direct local `./build` is unchanged; CI is the enforced surface in this change.

## Intentional rollback

Edit `manifests/first-party-pin-overrides.json` in the **same reviewed PR** as
the rollback. It is an empty list normally. Each exception binds an exact
subject, exact raw pin, exact observed released version, a non-empty reason,
and an inclusive UTC expiry date:

```json
[
  {
    "subject": "gstreamer1.0-rockchip-ceralive[arm64]",
    "pinned": "1.14.4+ceralive.4",
    "released": "1.14.4+ceralive.5",
    "reason": "Bisect the encoder regression; tracking issue #NNN",
    "expires": "2026-09-22"
  }
]
```

The output becomes `ROLLBACK` and prints the reason and expiry. There is no
environment-variable bypass, wildcard, or waiver for missing evidence.
A different pin or newer release invalidates the exception. Blank reasons,
expired/duplicate/unknown entries and unused exceptions fail. Remove the entry
when restoring currency. Existing artifact identity and qualification rules
remain in force; this exception authorizes only the currency comparison.

An app rollback usually needs three entries: `package[amd64]`,
`package[arm64]`, and `versions.yaml:component`. Copy the exact `pinned=` and
`released=` values from each diagnostic; provenance tags retain their prefix.
This prevents accidentally approving only one architecture or a stale banner.

The commented Radxa predecessor rows remain usable too. Restoring `librga2`
or `gstreamer1.0-rockchip1` is reported as stale **regardless of numeric
ordering**: Radxa's `2.2.0-1` is a packaging label, not a newer CeraLive API.
Use an exception naming the predecessor subject and version, with `released`
set to the CeraLive component tag. Restore the corresponding family/package
wiring as required by the existing gates; this guard does not rewrite it.

## Pinned versus installed: a separate advisory signal

The guard can read an **already captured** inventory without any board access:

```sh
python3 ci/check-first-party-pins.py --installed test-results/installed.tsv
```

The TSV has three columns: Debian package name, architecture, installed
version. An operator can later collect it with
`dpkg-query -W -f='${Package}\t${Architecture}\t${Version}\n'` on the device;
no collection, SSH, service, capture, or hardware command is run by the guard.

It reports `INSTALLED-NEWER`, `INSTALLED-OLDER`, `INSTALLED-MATCH`,
`INSTALLED-BUILD-DRIFT`, `INSTALLED-UNCOMPARABLE`, or `NOT-OBSERVED` per image
package/architecture. Partial inventories are labelled, never assumed matched.
Installed drift is advisory because operator-driven APT updates are legitimate;
it does not waive or strengthen the independent release-pin verdict.
Automated inventory collection or surfacing this in CeraUI belongs in a
separate diagnostics change. No new board observations are claimed here.
