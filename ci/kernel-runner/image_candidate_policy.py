"""The public, path-free candidate approval shared by the sealer and guest."""

import re
from typing import Final, TypedDict

from image_stream import StreamError

FIELD: Final = "measurement_candidate"
KIND: Final = "measurement-candidate"
METADATA: Final = ("kernel-artifact.json", "resolved.config", "built-modules.txt", "SHA256SUMS")
PROOF: Final = ("candidate.json", "publish-authorization.inputs.json", "BUNDLE.SHA256SUMS")
BOARDS: Final = ("orange-pi-5-plus", "rock-5b-plus")
SHA: Final = re.compile(r"[0-9a-f]{64}")
VERSION: Final = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+-ceralive[1-9][0-9]*")
INPUT_LIMIT: Final = 32 * 1024**3


class Pin(TypedDict):
    sha256: str
    length: int


class Approval(TypedDict):
    package: str
    version: str
    arch: str
    validated_boards: list[str]
    input_fingerprint: str
    producer_commit: str
    candidate_run_id: str
    payloads: dict[str, Pin]
    proof: dict[str, Pin]


def parse_approval(selected: Approval) -> Approval:
    """Require one complete approval in the same wire format on both sides."""
    if (type(selected) is not dict or set(selected) != Approval.__annotations__.keys()
            or any(type(selected[key]) is not str for key in (
                "package", "version", "arch", "input_fingerprint", "producer_commit", "candidate_run_id"))):
        raise StreamError("invalid measurement-candidate policy fields or types")
    package, version, arch = (selected[key] for key in ("package", "version", "arch"))
    boards = selected["validated_boards"]
    if (not VERSION.fullmatch(version) or package != f"linux-image-{version.split('-ceralive')[0]}-ceralive-rk3588"
            or arch != "arm64" or type(boards) is not list or not all(type(board) is str for board in boards)
            or sorted(boards) != list(BOARDS) or not SHA.fullmatch(selected["input_fingerprint"])
            or not re.fullmatch(r"[0-9a-f]{40}", selected["producer_commit"])
            or not re.fullmatch(r"[1-9][0-9]*", selected["candidate_run_id"])):
        raise StreamError("invalid measurement-candidate policy identity")
    deb = f"{package}_{version}_{arch}.deb"
    digests = set()
    for key, names in (("payloads", {deb, *METADATA}), ("proof", set(PROOF))):
        pins = selected[key]
        if type(pins) is not dict or pins.keys() != names:
            raise StreamError("invalid measurement-candidate policy file closure")
        for name, pin in pins.items():
            if (type(pin) is not dict or pin.keys() != {"sha256", "length"}
                    or type(pin["sha256"]) is not str or not SHA.fullmatch(pin["sha256"])
                    or type(pin["length"]) is not int
                    or not 0 < pin["length"] <= (INPUT_LIMIT if name == deb else 16 * 1024**2)
                    or pin["sha256"] in digests):
                raise StreamError("invalid measurement-candidate policy file pin")
            digests.add(pin["sha256"])
    return selected
