#!/usr/bin/env python3
"""EDID conformance checker + negative-fixture generator for the HDMI-RX blob.

WHY THIS EXISTS RATHER THAN A BARE `edid-decode --check`. The CI job
`edid-conformance` in .github/workflows/v2-ci.yml already proves the committed
blob is a VALID EDID and carries the 4K60 capabilities, and it does that with
`edid-decode` plus thirteen content assertions. Two things stop the default
`./run-tests` gate reusing that shape:

  * `edid-decode` is its own Debian package and is NOT installed on every host
    that runs `./run-tests` (it is not in the device image either). A leg that
    silently skips when the tool is absent is a leg that proves nothing.
  * structural validity and capability CONTENT are two different verdicts. The
    4K30-only negative fixture below keeps BOTH block checksums valid, so every
    checksum-shaped check passes it; only a check that asks for VIC 97, 600 MHz
    and SCDC by name rejects it. That is the whole reason the CI job pairs
    `--check` with thirteen content assertions rather than trusting `--check`.

This checker therefore reimplements both halves against the raw bytes with the
stdlib only, so the contract suite is host-independent and neither half can go
vacuous. It is scoped to the properties the CeraLive 4K60 capture leg actually
depends on; it is NOT a general EDID validator and must not grow into one.

Byte layout references are EDID 1.4 (base block) and CTA-861 (extension block);
the same structures the generator builds by name in tools/gen-hdmirx-edid.py.
"""

from __future__ import annotations

import argparse
import sys
from typing import Iterator, NamedTuple

BLOCK_LEN = 128
EDID_LEN = 2 * BLOCK_LEN
EDID_HEADER = bytes([0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00])

CTA_EXTENSION_TAG = 0x02
CTA_MIN_REVISION = 3
CTA_TAG_VIDEO = 0x02
CTA_TAG_VENDOR = 0x03

# OUI C4-5D-D8 as it appears on the wire (little-endian): the HDMI Forum VSDB,
# the ONLY block that can express a >340 MHz TMDS rate and SCDC support.
HF_VSDB_OUI = bytes([0xD8, 0x5D, 0xC4])
SCDC_PRESENT_BIT = 0x80
TMDS_UNIT_MHZ = 5
REQUIRED_TMDS_MHZ = 600
VIC_3840X2160P60 = 97
VIC_3840X2160P50 = 96

# Replacement VICs for the 4K30-only negative fixture. Both are legal CTA VICs
# absent from the real blob's list, so the fixture reads as a sink that
# deliberately tops out at 4K30 rather than as random corruption — and its two
# block checksums stay valid, which is exactly the case a checksum-shaped check
# cannot catch.
VIC_1920X1080P120 = 63
VIC_1920X1080P100 = 64
TMDS_300_MHZ = 0x3C


class DataBlock(NamedTuple):
    tag: int
    start: int
    length: int


def block_checksum_ok(block: bytes) -> bool:
    return sum(block) % 256 == 0


def reseal(block: bytearray) -> None:
    block[BLOCK_LEN - 1] = (-sum(block[: BLOCK_LEN - 1])) & 0xFF


def cta_data_blocks(ext: bytes) -> Iterator[DataBlock]:
    """Walk the CTA-861 data block collection; offsets are relative to `ext`."""
    dtd_offset = ext[2]
    if dtd_offset < 4:
        return
    index = 4
    while index < min(dtd_offset, BLOCK_LEN - 1):
        length = ext[index] & 0x1F
        yield DataBlock(tag=ext[index] >> 5, start=index + 1, length=length)
        index += 1 + length


def find_hf_vsdb(ext: bytes) -> DataBlock | None:
    for block in cta_data_blocks(ext):
        payload = ext[block.start : block.start + block.length]
        if block.tag == CTA_TAG_VENDOR and payload[:3] == HF_VSDB_OUI:
            return block
    return None


def short_video_descriptors(ext: bytes) -> list[int]:
    vics: list[int] = []
    for block in cta_data_blocks(ext):
        if block.tag == CTA_TAG_VIDEO:
            payload = ext[block.start : block.start + block.length]
            vics.extend(byte & 0x7F for byte in payload)
    return vics


class Report:
    def __init__(self) -> None:
        self.failed = False

    def check(self, label: str, condition: bool, detail: str = "") -> bool:
        if condition:
            print(f"  ok   {label}")
            return True
        self.failed = True
        print(f"  FAIL {label}{': ' + detail if detail else ''}")
        return False


def check_edid(data: bytes) -> int:
    report = Report()

    if not report.check(
        "EDID is 256 bytes (base + one extension)",
        len(data) == EDID_LEN,
        f"got {len(data)} bytes",
    ):
        return 1

    base, ext = data[:BLOCK_LEN], data[BLOCK_LEN:]

    report.check("base block carries the EDID header", base[:8] == EDID_HEADER)
    report.check("base block checksum is valid", block_checksum_ok(base))
    report.check("extension block checksum is valid", block_checksum_ok(ext))

    is_cta = report.check(
        "extension is a CTA-861 block, revision >= 3",
        ext[0] == CTA_EXTENSION_TAG and ext[1] >= CTA_MIN_REVISION,
        f"tag=0x{ext[0]:02x} rev={ext[1]}",
    )
    if not is_cta:
        return 1

    vics = short_video_descriptors(ext)
    report.check(
        f"VIC {VIC_3840X2160P60} (3840x2160p60) is offered",
        VIC_3840X2160P60 in vics,
        f"SVD list: {vics}",
    )
    report.check(
        f"VIC {VIC_3840X2160P50} (3840x2160p50) is offered",
        VIC_3840X2160P50 in vics,
    )

    hf_vsdb = find_hf_vsdb(ext)
    if not report.check("HDMI Forum VSDB (OUI C4-5D-D8) is present", hf_vsdb is not None):
        return 1
    assert hf_vsdb is not None

    payload = ext[hf_vsdb.start : hf_vsdb.start + hf_vsdb.length]
    if not report.check(
        "HF-VSDB carries the TMDS rate and SCDC bytes",
        len(payload) >= 6,
        f"payload is {len(payload)} bytes",
    ):
        return 1

    tmds_mhz = payload[4] * TMDS_UNIT_MHZ
    report.check(
        f"Maximum TMDS Character Rate is >= {REQUIRED_TMDS_MHZ} MHz",
        tmds_mhz >= REQUIRED_TMDS_MHZ,
        f"declared {tmds_mhz} MHz",
    )
    report.check("SCDC Present", bool(payload[5] & SCDC_PRESENT_BIT))

    return 1 if report.failed else 0


def make_bad_checksum(data: bytes) -> bytes:
    """Corrupt the base block's checksum byte and NOTHING else."""
    out = bytearray(data)
    out[BLOCK_LEN - 1] ^= 0xFF
    return bytes(out)


def make_4k30_no_scdc(data: bytes) -> bytes:
    """A checksum-valid EDID whose highest 4K mode is p30 and which has no SCDC."""
    out = bytearray(data)
    ext = memoryview(out)[BLOCK_LEN:]

    replaced = 0
    for block in cta_data_blocks(bytes(ext)):
        if block.tag != CTA_TAG_VIDEO:
            continue
        for offset in range(block.start, block.start + block.length):
            if ext[offset] & 0x7F == VIC_3840X2160P60:
                ext[offset] = VIC_1920X1080P120
                replaced += 1
            elif ext[offset] & 0x7F == VIC_3840X2160P50:
                ext[offset] = VIC_1920X1080P100
                replaced += 1
    if replaced != 2:
        raise SystemExit(f"expected to replace 2 4K60/50 VICs, replaced {replaced}")

    hf_vsdb = find_hf_vsdb(bytes(ext))
    if hf_vsdb is None:
        raise SystemExit("source EDID has no HF-VSDB to downgrade")
    ext[hf_vsdb.start + 4] = TMDS_300_MHZ
    ext[hf_vsdb.start + 5] &= ~SCDC_PRESENT_BIT & 0xFF

    tail = bytearray(out[BLOCK_LEN:])
    reseal(tail)
    out[BLOCK_LEN:] = tail
    return bytes(out)


NEGATIVES = {
    "bad-checksum": make_bad_checksum,
    "4k30-no-scdc": make_4k30_no_scdc,
}


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)

    check = sub.add_parser("check", help="assert an EDID is valid AND 4K60-capable")
    check.add_argument("edid")

    negative = sub.add_parser(
        "make-negative", help="derive a negative fixture from a known-good EDID"
    )
    negative.add_argument("kind", choices=sorted(NEGATIVES))
    negative.add_argument("source")
    negative.add_argument("destination")

    args = parser.parse_args(argv)

    if args.command == "check":
        with open(args.edid, "rb") as handle:
            return check_edid(handle.read())

    with open(args.source, "rb") as handle:
        source = handle.read()
    if len(source) != EDID_LEN:
        raise SystemExit(f"source EDID is {len(source)} bytes, expected {EDID_LEN}")
    with open(args.destination, "wb") as handle:
        handle.write(NEGATIVES[args.kind](source))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
