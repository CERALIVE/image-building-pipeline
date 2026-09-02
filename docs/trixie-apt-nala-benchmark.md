# Trixie builder apt transport benchmark

Todo 11 benchmarked the canonical package set from `ci/Dockerfile` lines 108–125
on the native Linux Docker daemon (`DOCKER_CONTEXT=default`, 2026-09-01). Each
measurement is a fresh `debian:trixie-slim` container; cold runs used a fresh
cache volume, while warm runs reused the same BuildKit-equivalent apt archive
and list mounts after one unmeasured seed install. Bytes are the apt summary's
reported archive total (`Need to get`); warm runs report the cached total too.

| transport | run | wall time (s) | archive bytes reported |
|---|---:|---:|---:|
| `apt-get` cold | 1 | 39.25 | 126 MB (126,000,000 B displayed-unit equivalent) |
| `apt-get` cold | 2 | 37.83 | 126 MB (126,000,000 B displayed-unit equivalent) |
| `apt-get` cold | 3 | 49.96 | 126 MB (126,000,000 B displayed-unit equivalent) |
| `nala` cold | 1 | 0.70 | unavailable (0 B downloaded) |
| `nala` cold | 2 | 0.64 | unavailable (0 B downloaded) |
| `nala` cold | 3 | 0.65 | unavailable (0 B downloaded) |
| `apt-get` warm via cache mounts | 1 | 34.26 | 0 B / 126 MB cached |
| `apt-get` warm via cache mounts | 2 | 34.48 | 0 B / 126 MB cached |
| `apt-get` warm via cache mounts | 3 | 34.33 | 0 B / 126 MB cached |

`nala` is not installed in the canonical builder container, so its three cold
measurements are explicit availability evidence rather than a silent omission.
The verdict is **keep `apt-get`; do not adopt `nala` in a build path**. The
warm cache avoided all 126 MB of payload transfer and reduced elapsed time in
these runs; `nala` cannot be compared until a separately approved image change
provides it. No `nala fetch` or mirror mutation was run.
