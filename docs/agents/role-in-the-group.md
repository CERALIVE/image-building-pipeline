<!-- Moved verbatim from AGENTS.md on 2026-10-05 by lean-rules-docs-landing-latam -->

## ROLE IN THE GROUP

Assembly hub for the device image. Pulls every device-side first-party component
(.deb packages from `srtla`, `cerastream`, `CeraUI`), drives a
containerized mkosi v26 build, and produces a flashable image for RK3588 targets
(Orange Pi 5+, Radxa Rock 5B+).

Relates to:
- `cert-work/` — GPG signing key injected into image; mTLS certs baked in; add-on keyring sourced from here; PASETO device-token PUBLIC key (`paseto/`) provisioned into the CeraUI runtime env
- `apt-worker/` — runtime apt source on device points to `apt.ceralive.tv` (Cloudflare R2); add-on `.raw` artifacts served from R2 path `addons/{os_version}/{board}/{feature}.raw`
- `versions.yaml` — standalone pin registry consumed by `fetch-debs.sh` [EXISTS]

