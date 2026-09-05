#!/usr/bin/env python3
"""Emit the CeraLive-branded HDMI-RX product EDIDs (256 bytes each, 2 blocks).

WHY THIS EXISTS
---------------
The mainline `snps_hdmirx` driver refuses to invent an EDID for you. Its own
Kconfig says a production device must load a CUSTOM, BRANDED EDID from
userspace, because the EDID is what the attached camera reads to decide which
modes it may send. Shipping a stock v4l-utils preset would advertise somebody
else's manufacturer ID and product name to every source we ever capture from.

TWO PROFILES, ONE GENERATOR
---------------------------
The receiver is programmed with exactly ONE of two blobs, selected on-device by
`hdmirx.edid_profile` in /data/ceralive/hdmirx.conf (see
mkosi/runtime/ceralive-hdmirx-edid.sh). They are two different NEGOTIATING
POSTURES against the same silicon, not two quality tiers:

  `full` (the default)
      The permissive advertisement: everything the receiver can actually take.
      4K60 at 594 MHz over RGB / 4:2:2, an HDMI Forum VSDB carrying
      Max_TMDS_Character_Rate = 600 MHz plus SCDC Present (the pair that makes
      4K60 legal for a source to offer at all), and a Y420CMDB additionally
      marking the two 4K60 modes as 4:2:0-capable.

  `robust-4k60`
      An HDMI 1.4-CLASS advertisement, offered deliberately so a source that
      cannot hold a clean 594 MHz link falls back to safer signalling instead of
      failing. It has NO HF-VSDB and therefore no SCDC and no >300 MHz claim;
      its 4K60 modes appear ONLY in a Y420VDB, i.e. as 4:2:0-only; and its
      preferred timing is 4K30 at 297 MHz with 1080p60 second. A source honouring
      it should send 4:2:0 at 297 MHz — below the scrambling threshold, so no
      SCDC ratio is needed — which the capture node then delivers as NV12, the
      encoder's native format, with zero conversion downstream.

      Whether a given real HDMI source actually PICKS 4:2:0 when offered this is
      an empirical, per-source question that can only be answered on a bench with
      that source attached. This generator's job is a correct, spec-conformant
      blob; it is not a claim about any camera's behaviour.

Y420CMDB vs Y420VDB IS THE LOAD-BEARING DISTINCTION, AND THEY ARE NOT
INTERCHANGEABLE. A Y420VDB (CTA extended tag 0x0E) is a list of VICs the sink
supports **ONLY** in 4:2:0 — a mode listed there and nowhere else cannot be sent
as RGB or 4:4:4 at all. A Y420CMDB (extended tag 0x0F) is a BITMAP over the
ordinary Video Data Block saying "these already-listed modes are ADDITIONALLY
4:2:0-capable". So `full`, whose 4K60 modes are genuinely RGB/4:2:2 capable,
must use the CAPABILITY MAP; using a Y420VDB there would be a lie that removes
the RGB path. `robust-4k60`, which deliberately claims 4K60 as 4:2:0-only, is
the one case where a Y420VDB is correct — and it must therefore also REMOVE
those VICs from the ordinary VDB, because a VIC present in both blocks is not
4:2:0-only.

THE 4:4:4 FLAG IS DROPPED FROM BOTH, ON PURPOSE. The CTA header's YCbCr 4:4:4
bit is absent because the engine cannot yet consume NV24. That is a DEFENSIVE
HONESTY posture, not a bug and not a limitation of the silicon: advertising a
pixel format we would then have to convert (or refuse) is how a source ends up
sending something the pipeline drops on the floor. YCbCr 4:2:2 stays.

DETERMINISM IS LOAD-BEARING
---------------------------
CI regenerates every profile's output and byte-compares it against the committed
blob; any drift fails the build. So NOTHING here may read the wall clock, the
environment, a random source, or a dict whose iteration order is not fixed.
The manufacture week/year below are FROZEN CONSTANTS for exactly that reason —
see MANUFACTURE_WEEK / MANUFACTURE_YEAR.

Stdlib only, by policy: this runs in a CI job that installs no Python packages.

Usage:
    tools/gen-hdmirx-edid.py --profile full \
        --output mkosi/runtime/edid/ceralive-hdmirx-full.edid
    tools/gen-hdmirx-edid.py --profile robust-4k60 --output -   # raw to stdout
    tools/gen-hdmirx-edid.py --list-profiles
"""

from __future__ import annotations

import argparse
import sys

# ---------------------------------------------------------------------------
# Identity contract — the whole reason this generator exists instead of a
# vendored upstream preset. Every value here is frozen; see the module docstring.
# ---------------------------------------------------------------------------

# Three uppercase letters, EDID's 5-bit-per-letter PNP form. NOTE: `CRL` is NOT
# a formally registered PNP ID — registering one with UEFI.org is deliberately
# OUT OF SCOPE here. It is unique enough for a first-party capture appliance and
# is what makes the EDID identifiably ours in a source's log or an
# `edid-decode` dump. Revisit only if a real registration is ever obtained.
MANUFACTURER_PNP_ID = "CRL"

PROFILE_FULL = "full"
PROFILE_ROBUST_4K60 = "robust-4k60"
PROFILES = (PROFILE_FULL, PROFILE_ROBUST_4K60)
DEFAULT_PROFILE = PROFILE_FULL

# EACH PROFILE GETS ITS OWN PRODUCT CODE, and that is a functional requirement
# rather than bookkeeping. A source caches an EDID keyed on manufacturer +
# product code + serial; two different advertisements sharing one code is how a
# camera keeps negotiating against the profile it read last week. 0x0001 was the
# pre-profile revision and is deliberately retired rather than reused: `full`'s
# capabilities changed in the same release that introduced profiles (Y420CMDB
# added, YCbCr 4:4:4 dropped, audio SADs extended), so per this file's own rule
# it owes a bump. Bump the code of any profile whose advertisement changes.
PRODUCT_CODES = {
    PROFILE_FULL: 0x0002,
    PROFILE_ROBUST_4K60: 0x0003,
}

SERIAL_NUMBER = 0  # 0 == "not used"; a per-device serial would break determinism

# FROZEN manufacture date. A build-time `date` here would make the output
# change every week and turn CI's byte-compare into permanent red. Week 1 of
# 2026 is simply the design date of this EDID, recorded once; bump it only
# alongside a PRODUCT_CODES entry if the advertised capabilities ever change.
MANUFACTURE_WEEK = 1
MANUFACTURE_YEAR = 2026

# Display Product Name descriptor payload. The EDID field is 13 bytes; a name
# SHORTER than 13 needs a 0x0A terminator plus 0x20 padding. "CeraLive HDMI" is
# exactly 13, so it fills the field with no terminator — asserted below. It is
# deliberately the SAME for both profiles: the profile is a negotiating posture,
# not a different product, and an operator reading a source's log should see one
# recognisable device name either way.
PRODUCT_NAME = "CeraLive HDMI"

EDID_VERSION = 1
EDID_REVISION = 3  # EDID 1.3 base block

# Physical panel size the DTDs also encode (96 cm x 54 cm == 960 mm x 540 mm).
IMAGE_SIZE_CM = (96, 54)
IMAGE_SIZE_MM = (960, 540)

BLOCK_LEN = 128


# ---------------------------------------------------------------------------
# Primitives
# ---------------------------------------------------------------------------


def checksum(block: bytes) -> int:
    """EDID block checksum: the byte that makes the 128-byte sum ≡ 0 (mod 256)."""
    return (-sum(block)) & 0xFF


def seal(block: bytearray) -> bytes:
    """Append the checksum to a 127-byte block body and return the full 128."""
    if len(block) != BLOCK_LEN - 1:
        raise ValueError(f"block body is {len(block)} bytes, expected {BLOCK_LEN - 1}")
    return bytes(block) + bytes([checksum(bytes(block))])


def pnp_id(letters: str) -> bytes:
    """Encode a 3-letter PNP manufacturer ID as EDID's big-endian 5-bit triple."""
    if len(letters) != 3 or not letters.isupper() or not letters.isalpha():
        raise ValueError(f"PNP ID must be 3 uppercase letters, got {letters!r}")
    packed = 0
    for letter in letters:
        packed = (packed << 5) | (ord(letter) - ord("A") + 1)
    return bytes([(packed >> 8) & 0x7F, packed & 0xFF])


def detailed_timing(
    *,
    pixel_clock_khz: int,
    hactive: int,
    hfront: int,
    hsync: int,
    hback: int,
    vactive: int,
    vfront: int,
    vsync: int,
    vback: int,
    hsize_mm: int,
    vsize_mm: int,
    hsync_positive: bool,
    vsync_positive: bool,
) -> bytes:
    """Encode one 18-byte Detailed Timing Descriptor (EDID 1.3 §3.10.2)."""
    hblank = hfront + hsync + hback
    vblank = vfront + vsync + vback
    clock_units = pixel_clock_khz // 10  # DTD stores the clock in 10 kHz units
    if clock_units * 10 != pixel_clock_khz:
        raise ValueError(f"pixel clock {pixel_clock_khz} kHz is not a 10 kHz multiple")

    # Sync-type bits 4:3 == 0b11 -> digital separate sync (the only sane choice
    # for an HDMI sink); bit2 vsync polarity, bit1 hsync polarity.
    flags = 0x18
    if vsync_positive:
        flags |= 0x04
    if hsync_positive:
        flags |= 0x02

    return bytes(
        [
            clock_units & 0xFF,
            (clock_units >> 8) & 0xFF,
            hactive & 0xFF,
            hblank & 0xFF,
            ((hactive >> 4) & 0xF0) | ((hblank >> 8) & 0x0F),
            vactive & 0xFF,
            vblank & 0xFF,
            ((vactive >> 4) & 0xF0) | ((vblank >> 8) & 0x0F),
            hfront & 0xFF,
            hsync & 0xFF,
            ((vfront & 0x0F) << 4) | (vsync & 0x0F),
            (((hfront >> 8) & 0x03) << 6)
            | (((hsync >> 8) & 0x03) << 4)
            | (((vfront >> 4) & 0x03) << 2)
            | ((vsync >> 4) & 0x03),
            hsize_mm & 0xFF,
            vsize_mm & 0xFF,
            ((hsize_mm >> 4) & 0xF0) | ((vsize_mm >> 8) & 0x0F),
            0x00,  # horizontal border
            0x00,  # vertical border
            flags,
        ]
    )


def display_descriptor(tag: int, payload: bytes) -> bytes:
    """Encode an 18-byte non-timing display descriptor: 00 00 00 <tag> 00 + 13."""
    if len(payload) != 13:
        raise ValueError(f"descriptor payload is {len(payload)} bytes, expected 13")
    return bytes([0x00, 0x00, 0x00, tag, 0x00]) + payload


def product_name_descriptor(name: str) -> bytes:
    """Display Product Name descriptor (tag 0xFC)."""
    raw = name.encode("ascii")
    if len(raw) > 13:
        raise ValueError(f"product name {name!r} exceeds the 13-byte EDID field")
    if len(raw) < 13:
        # Shorter names need the 0x0A terminator plus 0x20 padding. Kept for
        # correctness if PRODUCT_NAME is ever shortened; "CeraLive HDMI" is 13.
        raw = raw + b"\x0a" + b"\x20" * (12 - len(raw))
    return display_descriptor(0xFC, raw)


def range_limits_descriptor(
    *, v_min: int, v_max: int, h_min: int, h_max: int, max_pixel_clock_mhz: int
) -> bytes:
    """Display Range Limits descriptor (tag 0xFD), default-GTF flavour."""
    return display_descriptor(
        0xFD,
        bytes(
            [
                v_min,
                v_max,
                h_min,
                h_max,
                max_pixel_clock_mhz // 10,  # stored in 10 MHz units
                0x00,  # 0x00 == default GTF supported (no secondary curve)
                0x0A,
            ]
        )
        + b"\x20" * 6,
    )


def dummy_descriptor() -> bytes:
    """Dummy descriptor (tag 0x10) — pads an unused descriptor slot."""
    return display_descriptor(0x10, b"\x00" * 13)


# ---------------------------------------------------------------------------
# Block 0 — EDID 1.3 base block
# ---------------------------------------------------------------------------

# `full`'s preferred timing. First DTD + the "preferred timing mode" feature bit
# is what tells a source that 3840x2160p60 is the mode we actually want.
PREFERRED_TIMING_4K60 = detailed_timing(
    pixel_clock_khz=594_000,
    hactive=3840,
    hfront=176,
    hsync=88,
    hback=296,
    vactive=2160,
    vfront=8,
    vsync=10,
    vback=72,
    hsize_mm=IMAGE_SIZE_MM[0],
    vsize_mm=IMAGE_SIZE_MM[1],
    hsync_positive=True,
    vsync_positive=True,
)

# `robust-4k60`'s preferred timing: CTA VIC 95 (3840x2160p30) at exactly
# 297 MHz. Same active/blanking geometry as the 4K60 DTD above at half the
# clock, which is what puts it under the 340 MHz scrambling threshold. This is
# the whole point of the profile — the preferred timing must itself be a mode a
# source can drive without SCDC, or a receiver that has just been told there is
# no SCDC is being handed a mode it cannot legally send.
PREFERRED_TIMING_4K30 = detailed_timing(
    pixel_clock_khz=297_000,
    hactive=3840,
    hfront=176,
    hsync=88,
    hback=296,
    vactive=2160,
    vfront=8,
    vsync=10,
    vback=72,
    hsize_mm=IMAGE_SIZE_MM[0],
    vsize_mm=IMAGE_SIZE_MM[1],
    hsync_positive=True,
    vsync_positive=True,
)

# `robust-4k60`'s SECOND choice, in the base block's second descriptor slot:
# CTA VIC 16 (1920x1080p60) at its exact CEA timing, 148.5 MHz. A source that
# will not take the 4K30 preferred timing lands here rather than on whatever the
# established-timing fallback set happens to offer.
SECOND_TIMING_1080P60 = detailed_timing(
    pixel_clock_khz=148_500,
    hactive=1920,
    hfront=88,
    hsync=44,
    hback=148,
    vactive=1080,
    vfront=4,
    vsync=5,
    vback=36,
    hsize_mm=IMAGE_SIZE_MM[0],
    vsize_mm=IMAGE_SIZE_MM[1],
    hsync_positive=True,
    vsync_positive=True,
)

# Established Timings I & II — the legacy VESA fallback set (640x480 .. 1280x1024).
ESTABLISHED_TIMINGS = bytes([0x2F, 0xCF, 0x00])

# Standard Timing Identifications — eight legacy DMT modes. 0x0101 would mean
# "unused"; every slot here is populated, matching the upstream preset.
STANDARD_TIMINGS = bytes(
    [
        0x31, 0x59,  # 640x480 @ 85
        0x45, 0x59,  # 800x600 @ 85
        0x81, 0x80,  # 1280x1024 @ 60
        0x81, 0x40,  # 1280x960 @ 60
        0x90, 0x40,  # 1400x1050 @ 60
        0x95, 0x00,  # 1440x900 @ 60
        0xA9, 0x40,  # 1600x1200 @ 60
        0xB3, 0x00,  # 1680x1050 @ 60
    ]
)

# Colour characteristics (CIE chromaticity), verbatim from the upstream preset:
# a generic sRGB-ish primary set. An HDMI-RX sink does not render, so these are
# advertisement only — but they must be present and self-consistent for
# `edid-decode --check` to pass.
CHROMATICITY = bytes([0xEE, 0x91, 0xA3, 0x54, 0x4C, 0x99, 0x26, 0x0F, 0x50, 0x54])

# Feature support byte: RGB colour display (bits 4:3 = 01), sRGB is the default
# colour space (bit 2), the first DTD is the PREFERRED timing (bit 1), and
# continuous-frequency/GTF is supported (bit 0) — the last of which is what
# makes the Display Range Limits descriptor below mandatory.
FEATURE_SUPPORT = 0x0F


def base_descriptors(profile: str) -> list[bytes]:
    """The base block's four 18-byte descriptor slots, in order.

    The Display Range Limits descriptor is MANDATORY here (FEATURE_SUPPORT sets
    the continuous-frequency bit) and its max dotclock must cover every timing
    the whole EDID offers, or `edid-decode --check` reports the modes as out of
    range. `robust-4k60` can state an honest 300 MHz because its own highest
    timing is the 297 MHz preferred DTD: edid-decode does not hold the Y420VDB's
    nominal 594 MHz against it, since a 4:2:0 mode's TMDS character rate is half
    the nominal pixel clock — 297 MHz, exactly at the ceiling.
    """
    if profile == PROFILE_FULL:
        return [
            PREFERRED_TIMING_4K60,
            range_limits_descriptor(
                v_min=24, v_max=85, h_min=24, h_max=135, max_pixel_clock_mhz=600
            ),
            product_name_descriptor(PRODUCT_NAME),
            dummy_descriptor(),
        ]

    # robust-4k60 spends the slot `full` gives to a dummy descriptor on a real
    # second-choice timing instead. Two DTDs then two display descriptors is the
    # canonical EDID 1.3 ordering, so nothing is lost by dropping the padding.
    return [
        PREFERRED_TIMING_4K30,
        SECOND_TIMING_1080P60,
        range_limits_descriptor(
            v_min=24, v_max=85, h_min=24, h_max=135, max_pixel_clock_mhz=300
        ),
        product_name_descriptor(PRODUCT_NAME),
    ]


def build_base_block(profile: str) -> bytes:
    body = bytearray()
    body += bytes([0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00])  # header
    body += pnp_id(MANUFACTURER_PNP_ID)
    body += PRODUCT_CODES[profile].to_bytes(2, "little")
    body += SERIAL_NUMBER.to_bytes(4, "little")
    body += bytes([MANUFACTURE_WEEK, MANUFACTURE_YEAR - 1990])
    body += bytes([EDID_VERSION, EDID_REVISION])

    body += bytes([0x80])  # digital input (EDID 1.3 has no bit-depth field here)
    body += bytes([IMAGE_SIZE_CM[0], IMAGE_SIZE_CM[1]])
    body += bytes([0x78])  # display gamma 2.20 -> (2.20 * 100) - 100
    body += bytes([FEATURE_SUPPORT])
    body += CHROMATICITY
    body += ESTABLISHED_TIMINGS
    body += STANDARD_TIMINGS

    descriptors = base_descriptors(profile)
    if len(descriptors) != 4:
        raise ValueError(f"base block takes 4 descriptors, got {len(descriptors)}")
    for descriptor in descriptors:
        body += descriptor

    body += bytes([0x01])  # one extension block follows
    return seal(body)


# ---------------------------------------------------------------------------
# Block 1 — CTA-861 extension block
# ---------------------------------------------------------------------------

CTA_TAG_AUDIO = 1
CTA_TAG_VIDEO = 2
CTA_TAG_VENDOR = 3
CTA_TAG_SPEAKER_ALLOC = 4
CTA_TAG_EXTENDED = 7

CTA_EXT_VIDEO_CAPABILITY = 0x00
CTA_EXT_COLORIMETRY = 0x05
CTA_EXT_HDR_STATIC_METADATA = 0x06
# 0x0E and 0x0F are the two 4:2:0 blocks, and mixing them up is the one mistake
# this file exists to prevent — see the module docstring.
CTA_EXT_Y420VDB = 0x0E  # VICs supported ONLY in 4:2:0
CTA_EXT_Y420CMDB = 0x0F  # bitmap over the VDB: these are ALSO 4:2:0-capable
CTA_EXT_VIDEO_FORMAT_PREFERENCE = 0x0D


def cta_block(tag: int, payload: bytes) -> bytes:
    """Encode one CTA-861 data block: a (tag<<5 | length) header byte + payload."""
    if not 0 <= len(payload) <= 31:
        raise ValueError(f"CTA data block payload is {len(payload)} bytes (max 31)")
    return bytes([((tag & 0x07) << 5) | len(payload)]) + payload


def cta_extended_block(ext_tag: int, payload: bytes) -> bytes:
    return cta_block(CTA_TAG_EXTENDED, bytes([ext_tag]) + payload)


# Short Video Descriptors, in PREFERENCE ORDER — a source reads this list top
# down, so VIC 97 (3840x2160p60) and VIC 96 (3840x2160p50) lead deliberately.
# No native-mode bit (0x80) is set: the base block's preferred DTD already says
# which mode we want, and setting both is how sources end up disagreeing.
SHORT_VIDEO_DESCRIPTORS = [
    97,  # 3840x2160p60
    96,  # 3840x2160p50
    95,  # 3840x2160p30
    94,  # 3840x2160p25
    93,  # 3840x2160p24
    16,  # 1920x1080p60
    31,  # 1920x1080p50
    4,   # 1280x720p60
    19,  # 1280x720p50
    34,  # 1920x1080p30
    33,  # 1920x1080p25
    32,  # 1920x1080p24
    5,   # 1920x1080i60
    20,  # 1920x1080i50
    2,   # 720x480p60
    17,  # 720x576p50
    1,   # 640x480p60
]

# The two 4K60 modes, i.e. the ones each profile treats differently.
VICS_4K60 = (97, 96)

# Short Audio Descriptor: LPCM (format 1), 2 channels, 32/44.1/48/88.2/96 kHz,
# 16/20/24 bit. Paired with the Basic Audio bit in the CTA header byte below.
#
# 88.2 and 96 kHz are advertised even though the pipeline works at 48 kHz: the
# engine resamples on the way in, so accepting a higher-rate embedded stream is
# strictly better than refusing it and having the source fall back to no audio.
SHORT_AUDIO_DESCRIPTOR = bytes(
    [
        (1 << 3) | (2 - 1),  # format 1 (LPCM), max 2 channels
        0x1F,  # sample rates: 32 | 44.1 | 48 | 88.2 | 96 kHz
        0x07,  # sample sizes: 16 | 20 | 24 bit
    ]
)

# Speaker Allocation: FL/FR only (bit 0). An HDMI-RX capture leg is stereo.
SPEAKER_ALLOCATION = bytes([0x01, 0x00, 0x00])

# HDMI Licensing VSDB (OUI 00-0C-03). Source Physical Address 1.0.0.0 is the
# correct value for a ROOT sink's first input port (0.0.0.0 is the root itself).
# Max TMDS clock byte is in 5 MHz units: 0x3C == 300 MHz.
#
# 300 MHz is the honest number for THIS block, in both profiles, and it is not a
# typo for any of the other limits that get quoted around HDMI. It is what the
# legacy HDMI 1.4b VSDB field can express here; the separate 340 MHz figure
# people reach for is HDMI 2.0's SCRAMBLING THRESHOLD, which lives in the
# HF-VSDB and is a different field of a different block. In `full` the >300 MHz
# claim is made by the HF-VSDB below; in `robust-4k60` there is no HF-VSDB, so
# this 300 MHz IS the ceiling the profile advertises. "Correcting" this byte to
# 340 is a known trap in both directions.
HDMI_VSDB = bytes(
    [
        0x03, 0x0C, 0x00,  # OUI 00-0C-03, little-endian on the wire
        0x10, 0x00,  # source physical address 1.0.0.0
        0x00,  # no AI/DC/DVI-dual support flags
        0x3C,  # max TMDS clock 300 MHz (5 MHz units)
        0x21,  # latency fields absent; HDMI_Video_present + content types
        0x00,  # supported content types: graphics
        0x60,  # HDMI_VIC_LEN = 3 (bits 7:5)
        0x01, 0x02, 0x03,  # HDMI VICs 1/2/3 (4K30 / 4K25 / 4K24)
    ]
)

# HDMI Forum VSDB (OUI C4-5D-D8). THE block that makes 4K60 possible, and the
# block `robust-4k60` deliberately omits entirely:
# Max_TMDS_Character_Rate is in 5 MHz units, so 0x78 == 120 * 5 == 600 MHz, and
# SCDC Present (bit 7 of the next byte) is what lets a source enable the
# TMDS scrambling required above 340 MHz. Drop either and a camera silently
# falls back to 4K30 — which for `full` is a defect and for `robust-4k60` is
# precisely the intent.
HF_VSDB = bytes(
    [
        0xD8, 0x5D, 0xC4,  # OUI C4-5D-D8, little-endian on the wire
        0x01,  # HF-VSDB version 1
        0x78,  # Max_TMDS_Character_Rate = 600 MHz (5 MHz units)
        0x80,  # SCDC_Present
        0x08,  # supports UHD VIC
    ]
)

# Video Capability: RGB and YCbCr quantization both selectable via AVI infoframe;
# IT and CE content always underscanned.
VIDEO_CAPABILITY = bytes([0xCA])

COLORIMETRY = bytes([0x00, 0x00])

# HDR Static Metadata: traditional gamma / SDR luminance only. This is an
# honest declaration — the capture leg does no HDR tone handling.
HDR_STATIC_METADATA = bytes([0x01, 0x00])

# CTA detailed timings. `full` leads with a 533.25 MHz 4K60 CVT-RB descriptor;
# `robust-4k60` starts at index 1, because a >297 MHz descriptor anywhere in the
# blob would contradict the ceiling the profile is built to advertise.
CTA_DETAILED_TIMINGS = [
    # 3840x2160 @ ~60 Hz, CVT reduced blanking (533.25 MHz).
    detailed_timing(
        pixel_clock_khz=533_250,
        hactive=3840,
        hfront=48,
        hsync=32,
        hback=80,
        vactive=2160,
        vfront=3,
        vsync=5,
        vback=54,
        hsize_mm=IMAGE_SIZE_MM[0],
        vsize_mm=IMAGE_SIZE_MM[1],
        hsync_positive=True,
        vsync_positive=True,
    ),
    # 1920x1080 @ ~60 Hz, CVT reduced blanking (138.50 MHz).
    detailed_timing(
        pixel_clock_khz=138_500,
        hactive=1920,
        hfront=48,
        hsync=32,
        hback=80,
        vactive=1080,
        vfront=3,
        vsync=5,
        vback=23,
        hsize_mm=IMAGE_SIZE_MM[0],
        vsize_mm=IMAGE_SIZE_MM[1],
        hsync_positive=True,
        vsync_positive=False,
    ),
    # 1280x720 @ ~60 Hz (74.50 MHz).
    detailed_timing(
        pixel_clock_khz=74_500,
        hactive=1280,
        hfront=64,
        hsync=128,
        hback=192,
        vactive=720,
        vfront=3,
        vsync=5,
        vback=20,
        hsize_mm=IMAGE_SIZE_MM[0],
        vsize_mm=IMAGE_SIZE_MM[1],
        hsync_positive=False,
        vsync_positive=True,
    ),
]

# CTA header byte 3: underscan by default (0x80), BASIC AUDIO (0x40) — the bit
# that pairs with the LPCM SAD above — YCbCr 4:2:2 (0x10), and a native-DTD
# count of 1 in the low nibble.
#
# THE YCbCr 4:4:4 BIT (0x20) IS ABSENT FROM BOTH PROFILES, DELIBERATELY. See the
# module docstring: the engine cannot consume NV24, so advertising 4:4:4 invites
# a source to send a format the pipeline would have to drop. Re-adding it is a
# claim about the ENGINE, not about the receiver, and belongs with the change
# that teaches the engine to accept NV24.
CTA_FLAGS = 0x80 | 0x40 | 0x10 | 0x01


def y420cmdb_bitmap(svds: list[int], capable: tuple[int, ...]) -> bytes:
    """Bitmap payload of a Y420CMDB: bit N == SVD N of the VDB is also 4:2:0.

    Bit ordering is LSB-first within each byte and the index is the SVD's
    POSITION IN THE VIDEO DATA BLOCK, not its VIC. Deriving it from the live SVD
    list rather than hardcoding a byte is what keeps the two in step: reordering
    or inserting an SVD silently repoints a hardcoded bitmap at the wrong modes,
    and nothing about the resulting EDID is structurally invalid.
    """
    bitmap = bytearray()
    for index, vic in enumerate(svds):
        if vic not in capable:
            continue
        byte = index // 8
        while len(bitmap) <= byte:
            bitmap.append(0x00)
        bitmap[byte] |= 1 << (index % 8)
    if not bitmap:
        raise ValueError(f"none of {capable} is present in the Video Data Block")
    return bytes(bitmap)


def cta_data_blocks(profile: str) -> bytes:
    if profile == PROFILE_FULL:
        svds = list(SHORT_VIDEO_DESCRIPTORS)
        # The 4K60 modes stay in the ordinary VDB (they are genuinely RGB/4:2:2
        # capable) and a CAPABILITY MAP says they are additionally 4:2:0.
        y420 = cta_extended_block(
            CTA_EXT_Y420CMDB, y420cmdb_bitmap(svds, VICS_4K60)
        )
        vendor_blocks = [
            cta_block(CTA_TAG_VENDOR, HDMI_VSDB),
            cta_block(CTA_TAG_VENDOR, HF_VSDB),
        ]
        preferred_format = 97  # 3840x2160p60
    else:
        # The 4K60 modes are REMOVED from the ordinary VDB and re-declared in a
        # Y420VDB. Leaving them in both blocks would mean "4:2:0 as well",
        # which is exactly the claim this profile exists not to make.
        svds = [vic for vic in SHORT_VIDEO_DESCRIPTORS if vic not in VICS_4K60]
        y420 = cta_extended_block(CTA_EXT_Y420VDB, bytes(VICS_4K60))
        vendor_blocks = [cta_block(CTA_TAG_VENDOR, HDMI_VSDB)]  # no HF-VSDB
        preferred_format = 95  # 3840x2160p30 — the profile's preferred DTD

    return b"".join(
        [
            cta_block(CTA_TAG_VIDEO, bytes(svds)),
            cta_block(CTA_TAG_AUDIO, SHORT_AUDIO_DESCRIPTOR),
            cta_block(CTA_TAG_SPEAKER_ALLOC, SPEAKER_ALLOCATION),
            *vendor_blocks,
            cta_extended_block(CTA_EXT_VIDEO_CAPABILITY, VIDEO_CAPABILITY),
            cta_extended_block(CTA_EXT_COLORIMETRY, COLORIMETRY),
            cta_extended_block(CTA_EXT_HDR_STATIC_METADATA, HDR_STATIC_METADATA),
            y420,
            # Restates the preferred format, so a source that ignores DTD order
            # still lands on the mode the profile's preferred DTD names.
            cta_extended_block(
                CTA_EXT_VIDEO_FORMAT_PREFERENCE, bytes([preferred_format])
            ),
        ]
    )


def build_cta_block(profile: str) -> bytes:
    data_blocks = cta_data_blocks(profile)

    # Byte 2 is the offset at which the DTDs start, i.e. 4 header bytes plus the
    # data-block collection. It is DERIVED, never hardcoded — a hardcoded value
    # silently truncates the collection the moment a data block is added.
    dtd_offset = 4 + len(data_blocks)

    body = bytearray([0x02, 0x03, dtd_offset, CTA_FLAGS])
    body += data_blocks
    timings = (
        CTA_DETAILED_TIMINGS if profile == PROFILE_FULL else CTA_DETAILED_TIMINGS[1:]
    )
    for timing in timings:
        body += timing

    if len(body) > BLOCK_LEN - 1:
        raise ValueError(f"CTA block overflows: {len(body)} bytes before checksum")
    body += b"\x00" * (BLOCK_LEN - 1 - len(body))
    return seal(body)


def build_edid(profile: str = DEFAULT_PROFILE) -> bytes:
    if profile not in PROFILES:
        raise ValueError(f"unknown profile {profile!r}; expected one of {PROFILES}")
    edid = build_base_block(profile) + build_cta_block(profile)
    if len(edid) != 2 * BLOCK_LEN:
        raise ValueError(f"EDID is {len(edid)} bytes, expected {2 * BLOCK_LEN}")
    return edid


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        description="Generate a CeraLive-branded HDMI-RX EDID (256 bytes).",
    )
    parser.add_argument(
        "-p",
        "--profile",
        choices=PROFILES,
        default=DEFAULT_PROFILE,
        help=f"advertisement profile to emit (default: {DEFAULT_PROFILE})",
    )
    parser.add_argument(
        "-o",
        "--output",
        default="-",
        help="destination file, or '-' for stdout (default: -)",
    )
    parser.add_argument(
        "--list-profiles",
        action="store_true",
        help="print the profile names, one per line, and exit",
    )
    args = parser.parse_args(argv)

    if args.list_profiles:
        for profile in PROFILES:
            print(profile)
        return 0

    edid = build_edid(args.profile)
    if args.output == "-":
        sys.stdout.buffer.write(edid)
    else:
        with open(args.output, "wb") as handle:
            handle.write(edid)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
