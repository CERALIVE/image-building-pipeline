"""Release identities and the image's actual package selectors."""
import re
import shlex
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Final
from urllib.parse import unquote, urlsplit


class PinError(ValueError):
    """An input cannot establish a trustworthy pin comparison."""


APP_COMPONENTS: Final = {
    "libsrt1.5-ceralive": "srt", "cerastream": "cerastream",
    "ceralive-device": "CeraUI", "srtla-send-rs": "srtla-send-rs",
    "gstreamer1.0-libuvch264src": "gstlibuvcsrc",
    "ceralive-modem-support": "modem-stack",
    "modemmanager": "modem-stack", "libmm-glib0": "modem-stack",
    "libmbim-glib4": "modem-stack", "libmbim-proxy": "modem-stack",
    "libmbim-utils": "modem-stack", "libqmi-glib5": "modem-stack",
    "libqmi-proxy": "modem-stack", "libqmi-utils": "modem-stack",
    "libqrtr-glib0": "modem-stack",
}
PLATFORM_COMPONENTS: Final = {
    "gstreamer1.0-rockchip-ceralive": "gstreamer-rockchip",
    "librga2-ceralive": "librga",
}
PREDECESSORS: Final = {
    "gstreamer1.0-rockchip1": "gstreamer-rockchip", "librga2": "librga",
}
EXTERNAL: Final = {"librockchip-mpp1", "rockchip-multimedia-config"}
COMPONENTS: Final = frozenset(APP_COMPONENTS.values()) | frozenset(PLATFORM_COMPONENTS.values())


def release_version(value: str) -> str:
    version = value.removeprefix("srt-v").removeprefix("v")
    # Only known observation/build suffixes are discarded; +ceralive.N is ordered.
    version = re.sub(r"(?:\+[0-9a-f]{7,40}|-\d{8}T\d{6}\.[0-9a-f]{7,40})$", "", version)
    if not re.fullmatch(r"\d+\.\d+\.\d+(?:\+ceralive\.\d+|-\d+~ceralive\.\d+)?", version):
        raise PinError(f"unsupported version: {value!r}")
    return version


def compare(left: str, right: str) -> int:
    a, b = release_version(left), release_version(right)
    for operator, result in (("lt", -1), ("gt", 1)):
        proc = subprocess.run(["dpkg", "--compare-versions", a, operator, b], check=False)
        if proc.returncode == 0:
            return result
        if proc.returncode != 1:
            raise PinError(f"dpkg comparison failed: {a} {operator} {b}")
    return 0


@dataclass(frozen=True, slots=True)
class Pin:
    component: str
    subject: str
    version: str
    package: str = ""
    arch: str = ""
    replacement: bool = False


def active_lines(path: Path) -> list[str]:
    return [line.strip() for line in path.read_text().splitlines()
            if line.strip() and not line.lstrip().startswith("#")]


def array_names(root: Path, name: str) -> set[str]:
    text = (root / "lib/fetch-debs.sh").read_text()
    matches = re.findall(rf"^{name}=\(([^)]*)\)", text, re.M)
    if len(matches) != 1:
        raise PinError(f"expected one {name} array")
    result = shlex.split(matches[0], comments=True)
    if not result or len(result) != len(set(result)):
        raise PinError(f"empty or duplicate {name}")
    return set(result)


def image_pins(root: Path) -> tuple[Pin, ...]:
    packages = array_names(root, "FIRST_PARTY_APT_PKGS")
    if packages != APP_COMPONENTS.keys():
        raise PinError(f"unmapped/removed app packages: {packages ^ APP_COMPONENTS.keys()}")
    repos = array_names(root, "REPOS")
    if not repos <= COMPONENTS:
        raise PinError(f"unmapped image repos: {repos - COMPONENTS}")
    entries: dict[str, str] = {}
    for line in active_lines(root / "manifests/first-party-deb-versions.txt"):
        match = re.fullmatch(r"([a-z0-9.+-]+(?:\[(?:arm64|amd64)\])?)=(\S+)", line)
        if not match or match[1] in entries or match[1].split("[")[0] not in packages:
            raise PinError(f"invalid/duplicate/unmapped app pin: {line}")
        entries[match[1]] = match[2]
    pins: list[Pin] = []
    for package, component in APP_COMPONENTS.items():
        for arch in ("amd64", "arm64"):
            version = entries.get(f"{package}[{arch}]", entries.get(package))
            if version is None:
                raise PinError(f"missing pin: {package}[{arch}]")
            release_version(version)
            pins.append(Pin(component, f"{package}[{arch}]", version, package, arch))

    registry = root / "versions.yaml"
    text = registry.read_text()
    for component in sorted(set(APP_COMPONENTS.values())):
        blocks = re.findall(rf"^{re.escape(component)}:\n((?:[ \t].*\n|#.*\n|\n)*)", text, re.M)
        if len(blocks) != 1 or len(re.findall(r"^\s+pin:", blocks[0], re.M)) != 1:
            raise PinError(f"missing/duplicate registry pin: {component}")
        result = subprocess.run([
            "bash", "-c", 'source "$1"; get_pin "$2" "$3"', "pin-reader",
            str(root / "lib/shared/versions-lib.sh"), component, str(registry),
        ], text=True, capture_output=True, check=True, timeout=10)
        version = result.stdout.strip()
        release_version(version)
        pins.append(Pin(component, f"versions.yaml:{component}", version))

    seen: set[str] = set()
    for line in active_lines(root / "manifests/rk3588-userspace-deb-versions.txt"):
        fields = line.split()
        if len(fields) != 4:
            raise PinError(f"invalid platform row: {line}")
        package, filename, digest, url = fields
        if package in seen or not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise PinError(f"duplicate platform package or invalid digest: {package}")
        seen.add(package)
        if package in EXTERNAL:
            continue
        component = PLATFORM_COMPONENTS.get(package, PREDECESSORS.get(package))
        if component is None:
            raise PinError(f"unmapped platform package: {package}")
        match = re.fullmatch(rf"{re.escape(package)}_(.+)_(arm64)\.deb", filename)
        parsed = urlsplit(url)
        if not match or parsed.scheme != "https" or unquote(parsed.path.split("/")[-1]) != filename:
            raise PinError(f"platform filename/URL mismatch: {package}")
        replacement = package in PREDECESSORS
        if not replacement:
            parts = unquote(parsed.path).split("/")
            if parsed.netloc != "github.com" or len(parts) != 7 or parts[1:5] != ["CERALIVE", component, "releases", "download"]:
                raise PinError(f"wrong first-party release URL: {package}")
            if compare(parts[5], match[1]) != 0:
                raise PinError(f"platform tag/filename version mismatch: {package}")
        pins.append(Pin(component, f"{package}[arm64]", match[1], package, "arm64", replacement))
    for component in PLATFORM_COMPONENTS.values():
        if sum(pin.component == component for pin in pins) != 1:
            raise PinError(f"missing or ambiguous platform component: {component}")
    return tuple(pins)
