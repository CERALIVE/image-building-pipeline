# Contributing to CeraLive (Alpha)

Thank you for your interest in contributing! CeraLive is an open, community-driven project to build high‑quality streaming appliance images for RK3588 (and beyond). We welcome contributions from beginners to experts.

Status: Alpha — APIs, structure, and UX may evolve. Please open an issue before large changes.

License: By contributing, you agree your work is dual-licensed under MIT OR Apache-2.0, at your option.

## Ways to Contribute

- Report bugs and edge cases (with logs and steps to reproduce)
- Improve documentation (Quickstart, device notes, troubleshooting)
- Add board support (configs, patches, testing notes)
- Packaging (belacoder, srtla, srt, ceraui) and repo integration
- Performance/latency tuning and power management
- UI/UX feedback for first‑boot and management workflows

## Getting Started

1. Fork the repo and create a feature branch
2. Build locally with Docker (recommended):
```bash
./build.sh --device rock5bplus --environment docker --verbose
```
3. Test the image on hardware; collect logs under `armbian-build/output/logs/`
4. Submit a PR with a clear description and a checklist of what you tested

## Development Conventions

- Shell: `set -euo pipefail`, guard `systemctl` and network in chroot
- Keep user‑facing branding as CeraLive; internal tool paths may use `ceraui`
- Prefer Armbian userpatches: `userpatches/customize-image.sh`, overlays, configs
- Keep images minimal; avoid unnecessary packages and services
- Use vendor kernel branch for RK3588 stability; name outputs with `stable`

## Code Style

- Bash: explicit, defensive, small functions; meaningful names
- No hidden side effects; prefer idempotent steps in customization
- Add comments explaining the “why” (especially for hardware quirks)
- Don’t introduce interactive prompts in build scripts

## Commit Messages

- Prefix with area: `[build]`, `[docs]`, `[userpatches]`, `[device:rock5bplus]`
- Use imperative mood: "Add", "Fix", "Refactor"
- Reference issues when applicable: `Fixes #123`

## PR Checklist

- [ ] Builds locally with `--environment docker`
- [ ] Tested on device(s); attach relevant logs (`output/logs/*.log`)
- [ ] Doesn’t add unnecessary packages/services
- [ ] Updates docs if CLI or behavior changed
- [ ] Passes shellcheck where practical

## Filing Issues

Please include:
- Device (e.g., Rock 5B+, Orange Pi 5+), media used (SD/eMMC)
- Build command and commit hash
- Logs from `armbian-build/output/logs/` (attach or paste relevant parts)
- What you expected vs what happened

## Community and Conduct

Be respectful and constructive. We’re aiming to make streaming setups easier for everyone. Disagreements are fine—keep them technical and kind.

## Roadmap Highlights

- More boards (RK3588 variants, Intel/AMD micro‑PCs)
- Image updater pipeline and signed repositories
- First‑boot setup wizard and web UI
- Telemetry opt‑in for diagnostics (privacy‑first)

## License

Contributions are under the project’s license. By submitting a PR, you agree your work may be redistributed under the same terms.

Welcome aboard — let’s build a great streaming experience together! 🚀

## AI Documentation

This repository has an [`AGENTS.md`](AGENTS.md) (init-deep hierarchical AI documentation). For group-level context, see the root [`AGENTS.md`](../AGENTS.md) and [`ARCHITECTURE.md`](../ARCHITECTURE.md).
