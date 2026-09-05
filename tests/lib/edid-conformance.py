#!/usr/bin/env python3
"""EDID conformance checker + negative-fixture generator for the HDMI-RX blobs.

WHY THIS EXISTS RATHER THAN A BARE `edid-decode --check`. The CI job
`edid-conformance` in .github/workflows/v2-ci.yml already proves each committed
blob is a VALID EDID and carries its profile's capabilities, and it does that
with `edid-decode` plus a table of content assertions. Two things stop the
default `./run-tests` gate reusing that shape:

  * `edid-decode` is its own Debian package and is NOT installed on every host
    that runs `./run-tests` (it is not in the device image either). A leg that
    silently skips when the tool is absent is a leg that proves nothing.
  * structural validity and capability CONTENT are two different verdicts. Every
    negative fixture below keeps BOTH block checksums valid except the one whose
    whole point is a bad checksum, so every checksum-shaped check passes them;
    only a check that asks for the profile's blocks BY NAME rejects them.

This checker therefore reimplements both halves against the raw bytes with the
stdlib only, so the contract suite is host-independent and neither half can go
vacuous. It is scoped to the properties the CeraLive capture leg actually
depends on; it is NOT a general EDID validator and must not grow into one.

PROFILES ARE NOT TIERS, AND THE CHECK IS DIFFERENT FOR EACH. `full` and
`robust-4k60` are two negotiating postures, and several properties that are a
PASS for one are a FAIL for the other — an HF-VSDB is mandatory in `full` and
forbidden in `robust-4k60`; VIC 97/96 must be in the ordinary Video Data Block
for `full` and must NOT be for `robust-4k60`. So `check` takes the profile name
and there is deliberately no profile-agnostic mode: "does this blob conform"
is not a question that can be asked without saying conform to WHAT.

THE 4:2:0 BLOCKS ARE THE SHARP EDGE. A Y420VDB (extended tag 0x0E) lists VICs
supported ONLY in 4:2:0. A Y420CMDB (extended tag 0x0F) is a BITMAP over the
ordinary Video Data Block marking already-listed modes as ADDITIONALLY
4:2:0-capable. They differ by one byte on the wire and mean opposite things, and
a blob that swaps them is structurally valid — `edid-decode --check` passes it.
That is why each profile asserts the presence of its own block AND the ABSENCE
of the other, and why one of the negative fixtures below is exactly that swap.

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

# Offset of the first Detailed Timing Descriptor in the base block, and of the
# two little-endian bytes inside it that carry the pixel clock in 10 kHz units.
BASE_PREFERRED_DTD = 54

CTA_EXTENSION_TAG = 0x02
CTA_MIN_REVISION = 3
CTA_FLAGS_BYTE = 3
CTA_FLAG_YCBCR444 = 0x20
CTA_FLAG_YCBCR422 = 0x10
CTA_TAG_AUDIO = 0x01
CTA_TAG_VIDEO = 0x02
CTA_TAG_VENDOR = 0x03
CTA_TAG_EXTENDED = 0x07

CTA_EXT_Y420VDB = 0x0E
CTA_EXT_Y420CMDB = 0x0F

# OUI C4-5D-D8 as it appears on the wire (little-endian): the HDMI Forum VSDB,
# the ONLY block that can express a >340 MHz TMDS rate and SCDC support.
HF_VSDB_OUI = bytes([0xD8, 0x5D, 0xC4])
# OUI 00-0C-03: the legacy HDMI Licensing VSDB, present in BOTH profiles.
HDMI_VSDB_OUI = bytes([0x03, 0x0C, 0x00])
HDMI_VSDB_MAX_TMDS_OFFSET = 6

SCDC_PRESENT_BIT = 0x80
TMDS_UNIT_MHZ = 5
REQUIRED_TMDS_MHZ = 600
LEGACY_TMDS_MHZ = 300
VIC_3840X2160P60 = 97
VIC_3840X2160P50 = 96
VIC_3840X2160P30 = 95
VICS_4K60 = (VIC_3840X2160P60, VIC_3840X2160P50)

# The scrambling-free ceiling robust-4k60 is built around. A preferred timing
# above this would be a mode the profile has just told the source it cannot
# signal, because it advertises no SCDC.
ROBUST_MAX_PREFERRED_KHZ = 297_000

# Sample-rate bits of a Short Audio Descriptor's second byte.
SAD_RATE_32 = 0x01
SAD_RATE_44_1 = 0x02
SAD_RATE_48 = 0x04
SAD_RATE_88_2 = 0x08
SAD_RATE_96 = 0x10

PROFILE_FULL = "full"
PROFILE_ROBUST = "robust-4k60"
PROFILES = (PROFILE_FULL, PROFILE_ROBUST)

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


def payload_of(ext: bytes, block: DataBlock) -> bytes:
    return ext[block.start : block.start + block.length]


def find_vsdb(ext: bytes, oui: bytes) -> DataBlock | None:
    for block in cta_data_blocks(ext):
        if block.tag == CTA_TAG_VENDOR and payload_of(ext, block)[:3] == oui:
            return block
    return None


def find_extended(ext: bytes, ext_tag: int) -> DataBlock | None:
    for block in cta_data_blocks(ext):
        payload = payload_of(ext, block)
        if block.tag == CTA_TAG_EXTENDED and payload[:1] == bytes([ext_tag]):
            return block
    return None


def extended_payload(ext: bytes, ext_tag: int) -> bytes:
    """The bytes of an extended block AFTER its extended-tag byte."""
    block = find_extended(ext, ext_tag)
    return b"" if block is None else payload_of(ext, block)[1:]


def short_video_descriptors(ext: bytes) -> list[int]:
    vics: list[int] = []
    for block in cta_data_blocks(ext):
        if block.tag == CTA_TAG_VIDEO:
            vics.extend(byte & 0x7F for byte in payload_of(ext, block))
    return vics


def short_audio_descriptors(ext: bytes) -> list[bytes]:
    sads: list[bytes] = []
    for block in cta_data_blocks(ext):
        if block.tag != CTA_TAG_AUDIO:
            continue
        payload = payload_of(ext, block)
        sads.extend(payload[i : i + 3] for i in range(0, len(payload) - 2, 3))
    return sads


def y420cmdb_svd_indices(bitmap: bytes) -> list[int]:
    """SVD positions a Y420CMDB bitmap marks, LSB-first within each byte."""
    return [
        index * 8 + bit
        for index, byte in enumerate(bitmap)
        for bit in range(8)
        if byte & (1 << bit)
    ]


def preferred_dtd_clock_khz(base: bytes) -> int:
    lo, hi = base[BASE_PREFERRED_DTD], base[BASE_PREFERRED_DTD + 1]
    return (lo | (hi << 8)) * 10


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


def check_common(report: Report, base: bytes, ext: bytes) -> None:
    report.check("base block carries the EDID header", base[:8] == EDID_HEADER)
    report.check("base block checksum is valid", block_checksum_ok(base))
    report.check("extension block checksum is valid", block_checksum_ok(ext))

    flags = ext[CTA_FLAGS_BYTE]
    # Dropped on purpose in BOTH profiles: the engine cannot consume NV24, so
    # advertising 4:4:4 invites a format the pipeline would have to discard.
    report.check(
        "YCbCr 4:4:4 is NOT advertised (the engine cannot consume NV24)",
        not flags & CTA_FLAG_YCBCR444,
        f"CTA flags 0x{flags:02x}",
    )
    report.check("YCbCr 4:2:2 is advertised", bool(flags & CTA_FLAG_YCBCR422))

    hdmi_vsdb = find_vsdb(ext, HDMI_VSDB_OUI)
    if report.check("HDMI VSDB (OUI 00-0C-03) is present", hdmi_vsdb is not None):
        assert hdmi_vsdb is not None
        payload = payload_of(ext, hdmi_vsdb)
        legacy_mhz = payload[HDMI_VSDB_MAX_TMDS_OFFSET] * TMDS_UNIT_MHZ
        report.check(
            f"legacy HDMI VSDB max TMDS clock is {LEGACY_TMDS_MHZ} MHz",
            legacy_mhz == LEGACY_TMDS_MHZ,
            f"declared {legacy_mhz} MHz",
        )

    sads = short_audio_descriptors(ext)
    if report.check("an LPCM Short Audio Descriptor is present", bool(sads)):
        rates = sads[0][1]
        wanted = SAD_RATE_32 | SAD_RATE_44_1 | SAD_RATE_48 | SAD_RATE_88_2 | SAD_RATE_96
        report.check(
            "audio SADs offer 32/44.1/48/88.2/96 kHz",
            rates & wanted == wanted,
            f"rate bits 0x{rates:02x}",
        )


def check_full(report: Report, base: bytes, ext: bytes) -> None:
    vics = short_video_descriptors(ext)
    for vic in VICS_4K60:
        report.check(
            f"VIC {vic} is offered in the ordinary Video Data Block",
            vic in vics,
            f"SVD list: {vics}",
        )

    hf_vsdb = find_vsdb(ext, HF_VSDB_OUI)
    if report.check("HDMI Forum VSDB (OUI C4-5D-D8) is present", hf_vsdb is not None):
        assert hf_vsdb is not None
        payload = payload_of(ext, hf_vsdb)
        if report.check(
            "HF-VSDB carries the TMDS rate and SCDC bytes",
            len(payload) >= 6,
            f"payload is {len(payload)} bytes",
        ):
            tmds_mhz = payload[4] * TMDS_UNIT_MHZ
            report.check(
                f"Maximum TMDS Character Rate is >= {REQUIRED_TMDS_MHZ} MHz",
                tmds_mhz >= REQUIRED_TMDS_MHZ,
                f"declared {tmds_mhz} MHz",
            )
            report.check("SCDC Present", bool(payload[5] & SCDC_PRESENT_BIT))

    bitmap = extended_payload(ext, CTA_EXT_Y420CMDB)
    if report.check("Y420CMDB (4:2:0 capability map) is present", bool(bitmap)):
        marked = sorted(
            vics[i] for i in y420cmdb_svd_indices(bitmap) if i < len(vics)
        )
        report.check(
            "the Y420CMDB marks exactly the two 4K60 SVDs as also-4:2:0",
            marked == sorted(VICS_4K60),
            f"marks VICs {marked}",
        )
    # A Y420VDB here would mean "4:2:0 ONLY", removing the RGB/4:2:2 path from
    # modes this profile exists to offer at full bandwidth.
    report.check(
        "no Y420VDB (these modes are NOT 4:2:0-only)",
        find_extended(ext, CTA_EXT_Y420VDB) is None,
    )


def check_robust(report: Report, base: bytes, ext: bytes) -> None:
    vics = short_video_descriptors(ext)
    for vic in VICS_4K60:
        report.check(
            f"VIC {vic} is ABSENT from the ordinary Video Data Block",
            vic not in vics,
            f"SVD list: {vics}",
        )
    report.check(
        f"VIC {VIC_3840X2160P30} (4K30) is still offered",
        VIC_3840X2160P30 in vics,
    )

    y420vdb = extended_payload(ext, CTA_EXT_Y420VDB)
    if report.check("Y420VDB (4:2:0-only video) is present", bool(y420vdb)):
        listed = sorted(byte & 0x7F for byte in y420vdb)
        report.check(
            "the Y420VDB declares exactly the two 4K60 modes",
            listed == sorted(VICS_4K60),
            f"lists VICs {listed}",
        )
    # A capability map would say "these VDB modes are ALSO 4:2:0", which is the
    # opposite claim: this profile offers 4K60 in 4:2:0 and nothing else.
    report.check(
        "no Y420CMDB (4K60 is 4:2:0-ONLY here, not additionally-4:2:0)",
        find_extended(ext, CTA_EXT_Y420CMDB) is None,
    )

    report.check(
        "no HDMI Forum VSDB (so no SCDC and no >300 MHz claim)",
        find_vsdb(ext, HF_VSDB_OUI) is None,
    )

    clock_khz = preferred_dtd_clock_khz(base)
    report.check(
        f"preferred DTD pixel clock is <= {ROBUST_MAX_PREFERRED_KHZ // 1000} MHz",
        clock_khz <= ROBUST_MAX_PREFERRED_KHZ,
        f"declared {clock_khz / 1000:.3f} MHz",
    )


PROFILE_CHECKS = {PROFILE_FULL: check_full, PROFILE_ROBUST: check_robust}


def check_edid(profile: str, data: bytes) -> int:
    report = Report()

    if not report.check(
        "EDID is 256 bytes (base + one extension)",
        len(data) == EDID_LEN,
        f"got {len(data)} bytes",
    ):
        return 1

    base, ext = data[:BLOCK_LEN], data[BLOCK_LEN:]

    if not report.check(
        "extension is a CTA-861 block, revision >= 3",
        ext[0] == CTA_EXTENSION_TAG and ext[1] >= CTA_MIN_REVISION,
        f"tag=0x{ext[0]:02x} rev={ext[1]}",
    ):
        return 1

    check_common(report, base, ext)
    PROFILE_CHECKS[profile](report, base, ext)

    return 1 if report.failed else 0


# ---------------------------------------------------------------------------
# Negative fixtures — each is the SMALLEST edit that breaks one named property.
# ---------------------------------------------------------------------------


def make_bad_checksum(data: bytes) -> bytes:
    """Corrupt the base block's checksum byte and NOTHING else."""
    out = bytearray(data)
    out[BLOCK_LEN - 1] ^= 0xFF
    return bytes(out)


def make_4k30_no_scdc(data: bytes) -> bytes:
    """A checksum-valid `full` EDID whose highest 4K mode is p30, with no SCDC."""
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

    hf_vsdb = find_vsdb(bytes(ext), HF_VSDB_OUI)
    if hf_vsdb is None:
        raise SystemExit("source EDID has no HF-VSDB to downgrade")
    ext[hf_vsdb.start + 4] = TMDS_300_MHZ
    ext[hf_vsdb.start + 5] &= ~SCDC_PRESENT_BIT & 0xFF

    tail = bytearray(out[BLOCK_LEN:])
    reseal(tail)
    out[BLOCK_LEN:] = tail
    return bytes(out)


def make_y420_block_swap(data: bytes) -> bytes:
    """Swap a Y420VDB for a Y420CMDB (or back) by flipping ONE extended tag byte.

    This is the whole reason the checker asks for each block by name. One byte
    turns "4:2:0-only" into "additionally 4:2:0" — opposite claims about which
    pixel formats a source may send — and the result stays a structurally valid
    EDID that `edid-decode --check` accepts without complaint.
    """
    out = bytearray(data)
    ext = memoryview(out)[BLOCK_LEN:]

    for present, replacement in (
        (CTA_EXT_Y420VDB, CTA_EXT_Y420CMDB),
        (CTA_EXT_Y420CMDB, CTA_EXT_Y420VDB),
    ):
        block = find_extended(bytes(ext), present)
        if block is not None:
            ext[block.start] = replacement
            tail = bytearray(out[BLOCK_LEN:])
            reseal(tail)
            out[BLOCK_LEN:] = tail
            return bytes(out)

    raise SystemExit("source EDID carries neither a Y420VDB nor a Y420CMDB")


def make_robust_with_hf_vsdb(data: bytes) -> bytes:
    """Give a `robust-4k60` EDID back the HF-VSDB it exists to omit.

    Inserted immediately after the legacy HDMI VSDB, with the DTD offset shifted
    by the inserted length and both the trailing DTDs and the padding kept — so
    the ONLY property this fixture breaks is "no HDMI Forum VSDB", not the block
    collection's structure.
    """
    out = bytearray(data)
    ext = bytearray(out[BLOCK_LEN:])

    hdmi_vsdb = find_vsdb(bytes(ext), HDMI_VSDB_OUI)
    if hdmi_vsdb is None:
        raise SystemExit("source EDID has no HDMI VSDB to insert after")
    if find_vsdb(bytes(ext), HF_VSDB_OUI) is not None:
        raise SystemExit("source EDID already carries an HF-VSDB")

    payload = HF_VSDB_OUI + bytes([0x01, 0x78, 0x80, 0x08])
    injected = bytes([(CTA_TAG_VENDOR << 5) | len(payload)]) + payload
    at = hdmi_vsdb.start + hdmi_vsdb.length

    # The trailing zero padding absorbs the insertion; anything else would mean
    # the fixture had pushed a real descriptor out of the block. The checksum
    # byte itself is excluded from that window because reseal() rewrites it.
    displaced = ext[BLOCK_LEN - 1 - len(injected) : BLOCK_LEN - 1]
    if any(displaced):
        raise SystemExit("not enough padding to insert an HF-VSDB without loss")

    rebuilt = (ext[:at] + bytearray(injected) + ext[at:])[:BLOCK_LEN]
    rebuilt[2] += len(injected)
    reseal(rebuilt)
    out[BLOCK_LEN:] = rebuilt
    return bytes(out)


NEGATIVES = {
    "bad-checksum": make_bad_checksum,
    "4k30-no-scdc": make_4k30_no_scdc,
    "y420-block-swap": make_y420_block_swap,
    "robust-with-hf-vsdb": make_robust_with_hf_vsdb,
}


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)

    check = sub.add_parser(
        "check", help="assert an EDID conforms to one named profile"
    )
    check.add_argument("profile", choices=PROFILES)
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
            return check_edid(args.profile, handle.read())

    with open(args.source, "rb") as handle:
        source = handle.read()
    if len(source) != EDID_LEN:
        raise SystemExit(f"source EDID is {len(source)} bytes, expected {EDID_LEN}")
    with open(args.destination, "wb") as handle:
        handle.write(NEGATIVES[args.kind](source))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
