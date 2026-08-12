#!/usr/bin/env python3
"""Verify (and canonicalize) a signed CeraLive hardware-evidence receipt.

A hardware receipt is the only durable claim that a drill actually ran on a
board. It is therefore signed over RFC 8785 canonical JSON with a run-scoped
Ed25519 evidence key that is pre-bound in the physical-gate receipt, and this
verifier accepts a receipt only when every one of the following holds:

  * the file bytes are BYTE-FOR-BYTE the canonical reserialization of their own
    content (a receipt that is merely "equivalent JSON" is rejected, because the
    signature covers bytes and a reformat would otherwise silently detach it);
  * the detached signature verifies under the supplied public key;
  * the public key's SHA-256 fingerprint equals both the receipt's recorded
    ``evidence_key_fingerprint`` and the operator-supplied expected fingerprint;
  * the recorded target / todo / artifact tuple match what the caller asserts;
  * the command-manifest digest recomputes over the manifest's exact bytes;
  * every decisive-log digest recomputes;
  * the receipt has not been seen before (replay);
  * every required result marker is present.

``--self-test`` exercises the accept path and each rejection path above against
synthetic fixtures with a SCRATCH key generated in a temporary directory. It
touches no hardware and never reads or writes a real evidence key.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

SCHEMA_VERSION = 1

REQUIRED_TOP_LEVEL = (
    "schema_version",
    "todo",
    "target",
    "board",
    "artifact",
    "build_mode",
    "command_manifest",
    "decisive_logs",
    "markers",
    "evidence_key_fingerprint",
    "recorded_at",
)


class ReceiptError(Exception):
    """A named verification failure; ``code`` is the stable machine-readable reason."""

    def __init__(self, code: str, detail: str) -> None:
        super().__init__(f"{code}: {detail}")
        self.code = code
        self.detail = detail


# --------------------------------------------------------------------------
# RFC 8785 (JCS) canonical serialization.
# --------------------------------------------------------------------------
_ESCAPES = {
    ord('"'): '\\"',
    ord("\\"): "\\\\",
    0x08: "\\b",
    0x0C: "\\f",
    0x0A: "\\n",
    0x0D: "\\r",
    0x09: "\\t",
}


def _canon_string(value: str) -> str:
    out = ['"']
    for char in value:
        code = ord(char)
        if code in _ESCAPES:
            out.append(_ESCAPES[code])
        elif code < 0x20:
            out.append(f"\\u{code:04x}")
        else:
            out.append(char)
    out.append('"')
    return "".join(out)


def canonicalize(value: object) -> str:
    if value is None:
        return "null"
    if value is True:
        return "true"
    if value is False:
        return "false"
    if isinstance(value, str):
        return _canon_string(value)
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float):
        # RFC 8785's number rule is ECMAScript Number::toString. Receipts carry
        # digests, counters and timestamps, never measurements, so a float is a
        # schema mistake rather than a serialization problem worth solving.
        raise ReceiptError("schema-invalid", "receipt numbers must be integers")
    if isinstance(value, list):
        return "[" + ",".join(canonicalize(item) for item in value) + "]"
    if isinstance(value, dict):
        # RFC 8785 orders members by their UTF-16 code units, not by codepoint.
        items = sorted(value.items(), key=lambda kv: kv[0].encode("utf-16-be"))
        return "{" + ",".join(f"{_canon_string(k)}:{canonicalize(v)}" for k, v in items) + "}"
    raise ReceiptError("schema-invalid", f"unserializable receipt value of type {type(value).__name__}")


def canonical_bytes(value: object) -> bytes:
    return canonicalize(value).encode("utf-8")


# --------------------------------------------------------------------------
# Key / signature helpers (openssl subprocess: no third-party python dependency
# is required on a bench box or in CI).
# --------------------------------------------------------------------------
def _openssl(*args: str, stdin: bytes | None = None) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["openssl", *args], input=stdin, capture_output=True, check=False
    )


def public_key_fingerprint(pubkey: Path) -> str:
    result = _openssl("pkey", "-pubin", "-in", str(pubkey), "-pubout", "-outform", "DER")
    if result.returncode != 0:
        raise ReceiptError("evidence-key-mismatch", f"unreadable public key {pubkey}")
    return "sha256:" + hashlib.sha256(result.stdout).hexdigest()


def verify_signature(pubkey: Path, payload: Path, signature: Path) -> None:
    if not signature.is_file():
        raise ReceiptError("signature-invalid", f"missing detached signature {signature}")
    result = _openssl(
        "pkeyutl", "-verify", "-rawin", "-pubin",
        "-inkey", str(pubkey), "-in", str(payload), "-sigfile", str(signature),
    )
    if result.returncode != 0:
        raise ReceiptError("signature-invalid", result.stderr.decode(errors="replace").strip())


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


# --------------------------------------------------------------------------
# Verification
# --------------------------------------------------------------------------
def load_canonical_receipt(receipt: Path) -> tuple[dict, bytes]:
    raw = receipt.read_bytes()
    try:
        parsed = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ReceiptError("noncanonical-json", f"receipt is not readable UTF-8 JSON: {exc}") from exc
    if not isinstance(parsed, dict):
        raise ReceiptError("schema-invalid", "receipt root is not an object")
    if canonical_bytes(parsed) != raw:
        raise ReceiptError(
            "noncanonical-json",
            "receipt bytes are not the RFC 8785 canonical reserialization of their own content",
        )
    return parsed, raw


def assert_schema(receipt: dict) -> None:
    missing = [key for key in REQUIRED_TOP_LEVEL if key not in receipt]
    if missing:
        raise ReceiptError("schema-invalid", f"missing receipt fields: {', '.join(missing)}")
    if receipt["schema_version"] != SCHEMA_VERSION:
        raise ReceiptError(
            "schema-invalid",
            f"schema_version {receipt['schema_version']!r} != {SCHEMA_VERSION}",
        )


def assert_binding(receipt: dict, args: argparse.Namespace) -> None:
    if args.target is not None and receipt["target"] != args.target:
        raise ReceiptError("target-mismatch", f"receipt target {receipt['target']!r} != {args.target!r}")
    if args.todo is not None and receipt["todo"] != args.todo:
        raise ReceiptError("todo-mismatch", f"receipt todo {receipt['todo']!r} != {args.todo!r}")
    for pair in args.expect_artifact:
        key, _, expected = pair.partition("=")
        actual = receipt["artifact"].get(key)
        if actual != expected:
            raise ReceiptError(
                "artifact-mismatch", f"artifact.{key} is {actual!r}, expected {expected!r}"
            )
    if args.build_mode is not None and receipt["build_mode"] != args.build_mode:
        raise ReceiptError(
            "artifact-mismatch",
            f"build_mode {receipt['build_mode']!r} != {args.build_mode!r}",
        )


def assert_command_manifest(receipt: dict, base: Path, override: Path | None) -> None:
    entry = receipt["command_manifest"]
    path = override if override is not None else base / entry["path"]
    if not path.is_file():
        raise ReceiptError("command-manifest-mismatch", f"command manifest not found: {path}")
    actual = sha256_file(path)
    if actual != entry["sha256"]:
        raise ReceiptError(
            "command-manifest-mismatch",
            f"{path}: recorded {entry['sha256']}, recomputed {actual}",
        )


def assert_decisive_logs(receipt: dict, base: Path) -> None:
    if not receipt["decisive_logs"]:
        raise ReceiptError("decisive-log-mismatch", "receipt records no decisive logs")
    for entry in receipt["decisive_logs"]:
        path = base / entry["path"]
        if not path.is_file():
            raise ReceiptError("decisive-log-mismatch", f"decisive log not found: {path}")
        actual = sha256_file(path)
        if actual != entry["sha256"]:
            raise ReceiptError(
                "decisive-log-mismatch",
                f"{path}: recorded {entry['sha256']}, recomputed {actual}",
            )


def assert_markers(receipt: dict, required: list[str]) -> None:
    present = set(receipt["markers"])
    missing = [marker for marker in required if marker not in present]
    if missing:
        raise ReceiptError("missing-marker", f"required markers absent: {', '.join(missing)}")


def assert_not_replayed(raw: bytes, seen_db: Path | None) -> None:
    if seen_db is None:
        return
    digest = hashlib.sha256(raw).hexdigest()
    if seen_db.exists() and digest in seen_db.read_text().split():
        raise ReceiptError("replay", f"receipt {digest} has already been accepted")
    with seen_db.open("a") as handle:
        handle.write(digest + "\n")


def verify(args: argparse.Namespace) -> None:
    receipt_path = Path(args.receipt).resolve()
    base = Path(args.evidence_root).resolve() if args.evidence_root else receipt_path.parent
    receipt, raw = load_canonical_receipt(receipt_path)
    assert_schema(receipt)

    pubkey = Path(args.pubkey).resolve()
    fingerprint = public_key_fingerprint(pubkey)
    if fingerprint != receipt["evidence_key_fingerprint"]:
        raise ReceiptError(
            "evidence-key-mismatch",
            f"public key {fingerprint} is not the receipt's bound key {receipt['evidence_key_fingerprint']}",
        )
    if args.expect_key_fingerprint and fingerprint != args.expect_key_fingerprint:
        raise ReceiptError(
            "evidence-key-mismatch",
            f"public key {fingerprint} is not the pre-bound run key {args.expect_key_fingerprint}",
        )
    signature = Path(args.signature) if args.signature else receipt_path.with_suffix(".json.sig")
    verify_signature(pubkey, receipt_path, signature)

    assert_binding(receipt, args)
    assert_command_manifest(receipt, base, Path(args.command_manifest) if args.command_manifest else None)
    assert_decisive_logs(receipt, base)
    assert_markers(receipt, args.require)
    assert_not_replayed(raw, Path(args.seen_db) if args.seen_db else None)


# --------------------------------------------------------------------------
# self-test
# --------------------------------------------------------------------------
def _sign(receipt_path: Path, key: Path) -> Path:
    signer = Path(__file__).resolve().parent / "sign-hardware-receipt.sh"
    subprocess.run(
        ["bash", str(signer), "--receipt", str(receipt_path), "--key", str(key)],
        check=True, capture_output=True,
    )
    return receipt_path.with_suffix(".json.sig")


def _build_fixture(root: Path, key: Path, pubkey: Path) -> Path:
    manifest = root / "t46.commands.txt"
    manifest.write_text(
        "sudo mountpoint -q /sys/kernel/debug || sudo mount -t debugfs debugfs /sys/kernel/debug\n"
        "sudo /tmp/ceralive-qa/hw-smoke.sh --case encode\n"
        "sudo /tmp/ceralive-qa/hw-smoke.sh --case wifi\n"
    )
    dmesg = root / "t46.dmesg.log"
    dmesg.write_text("[    0.000000] Linux version 6.1.115-ceralive-vendor-rk35xx #1\n")
    receipt = {
        "schema_version": SCHEMA_VERSION,
        "todo": 46,
        "target": "board:rock-candidate",
        "board": {
            "board_id": "rock-5b-plus",
            "compatible": "ceralive-rock-5b-plus",
            "variant": "default",
        },
        "artifact": {
            "a_tree_hash": "0" * 40,
            "dtb": "rk3588-rock-5b-plus.dtb",
            "kernel_release": "6.1.115-ceralive-vendor-rk35xx",
            "loader_sha256": "1" * 64,
            "patches_commit": "2" * 40,
            "raw_sha256": "3" * 64,
        },
        "build_mode": "development-hardware-candidate",
        "rauc": {
            "deployment_mode": "physical",
            "root_fingerprint": "",
            "leaf_fingerprint": "",
            "eku": "",
        },
        "recovery_proof_marker": "prior-image-restore-verified",
        "command_manifest": {"path": manifest.name, "sha256": sha256_file(manifest)},
        "decisive_logs": [{"path": dmesg.name, "sha256": sha256_file(dmesg)}],
        "markers": ["encode", "wifi", "kernel-log-clean", "recovery-proof"],
        "evidence_key_fingerprint": public_key_fingerprint(pubkey),
        "recorded_at": "2026-08-10T00:00:00Z",
    }
    path = root / "t46.json"
    path.write_bytes(canonical_bytes(receipt))
    _sign(path, key)
    return path


def _args(**overrides) -> argparse.Namespace:
    base = dict(
        receipt=None, pubkey=None, signature=None, evidence_root=None,
        expect_key_fingerprint=None, target=None, todo=None, build_mode=None,
        expect_artifact=[], command_manifest=None, require=[], seen_db=None,
    )
    base.update(overrides)
    return argparse.Namespace(**base)


def self_test() -> int:
    failures = 0

    def leg(name: str, expect_code: str | None, args: argparse.Namespace) -> None:
        nonlocal failures
        try:
            verify(args)
            code = None
        except ReceiptError as exc:
            code = exc.code
        if code == expect_code:
            print(f"  ok   {name} -> {code or 'accepted'}")
        else:
            print(f"  FAIL {name}: expected {expect_code or 'accept'}, got {code or 'accept'}", file=sys.stderr)
            failures += 1

    with tempfile.TemporaryDirectory(prefix="ceralive-receipt-selftest.") as tmp:
        root = Path(tmp)
        # SCRATCH key only. Never the run-scoped evidence key, never a path under
        # the real secrets directory — this self-test proves the verifier, not a
        # real hardware run.
        key = root / "scratch-evidence-ed25519.pem"
        pubkey = root / "scratch-evidence-ed25519.pub.pem"
        subprocess.run(["openssl", "genpkey", "-algorithm", "ED25519", "-out", str(key)],
                       check=True, capture_output=True)
        os.chmod(key, 0o600)
        subprocess.run(["openssl", "pkey", "-in", str(key), "-pubout", "-out", str(pubkey)],
                       check=True, capture_output=True)
        other_key = root / "other.pem"
        other_pub = root / "other.pub.pem"
        subprocess.run(["openssl", "genpkey", "-algorithm", "ED25519", "-out", str(other_key)],
                       check=True, capture_output=True)
        subprocess.run(["openssl", "pkey", "-in", str(other_key), "-pubout", "-out", str(other_pub)],
                       check=True, capture_output=True)

        receipt = _build_fixture(root, key, pubkey)
        fingerprint = public_key_fingerprint(pubkey)
        seen = root / "seen.txt"

        accept = _args(
            receipt=str(receipt), pubkey=str(pubkey), expect_key_fingerprint=fingerprint,
            target="board:rock-candidate", todo=46,
            build_mode="development-hardware-candidate",
            expect_artifact=["dtb=rk3588-rock-5b-plus.dtb"],
            require=["encode", "wifi", "kernel-log-clean", "recovery-proof"],
            seen_db=str(seen),
        )
        leg("accepts a well-formed, correctly-signed receipt", None, accept)
        leg("rejects a replayed receipt", "replay",
            _args(**{**vars(accept), "seen_db": str(seen)}))
        leg("rejects a changed public key", "evidence-key-mismatch",
            _args(**{**vars(accept), "pubkey": str(other_pub), "seen_db": None}))
        leg("rejects a mismatched pre-bound fingerprint", "evidence-key-mismatch",
            _args(**{**vars(accept), "expect_key_fingerprint": "sha256:" + "0" * 64, "seen_db": None}))
        leg("rejects a mismatched target", "target-mismatch",
            _args(**{**vars(accept), "target": "board:orange-candidate", "seen_db": None}))
        leg("rejects a mismatched todo", "todo-mismatch",
            _args(**{**vars(accept), "todo": 47, "seen_db": None}))
        leg("rejects a mismatched artifact field", "artifact-mismatch",
            _args(**{**vars(accept), "expect_artifact": ["dtb=rk3588-orangepi-5-plus.dtb"], "seen_db": None}))
        leg("rejects a missing required marker", "missing-marker",
            _args(**{**vars(accept), "require": ["encode", "bluetooth"], "seen_db": None}))

        tampered_sig = root / "tampered"
        tampered_sig.mkdir()
        shutil.copy(receipt, tampered_sig / "t46.json")
        (tampered_sig / "t46.json.sig").write_bytes(b"\x00" * 64)
        shutil.copy(root / "t46.commands.txt", tampered_sig / "t46.commands.txt")
        shutil.copy(root / "t46.dmesg.log", tampered_sig / "t46.dmesg.log")
        leg("rejects a forged signature", "signature-invalid",
            _args(**{**vars(accept), "receipt": str(tampered_sig / "t46.json"), "seen_db": None}))

        noncanon = root / "noncanonical"
        noncanon.mkdir()
        parsed = json.loads(receipt.read_text())
        (noncanon / "t46.json").write_text(json.dumps(parsed, indent=2))
        # Signed with the RIGHT key over the WRONG bytes: the signature is
        # genuinely valid, so only the canonicality check can catch this.
        subprocess.run(
            ["openssl", "pkeyutl", "-sign", "-rawin", "-inkey", str(key),
             "-in", str(noncanon / "t46.json"), "-out", str(noncanon / "t46.json.sig")],
            check=True, capture_output=True,
        )
        shutil.copy(root / "t46.commands.txt", noncanon / "t46.commands.txt")
        shutil.copy(root / "t46.dmesg.log", noncanon / "t46.dmesg.log")
        leg("rejects pretty-printed (non-canonical) JSON even when validly signed",
            "noncanonical-json",
            _args(**{**vars(accept), "receipt": str(noncanon / "t46.json"), "seen_db": None}))

        altered_log = root / "altered-log"
        altered_log.mkdir()
        shutil.copy(receipt, altered_log / "t46.json")
        shutil.copy(root / "t46.json.sig", altered_log / "t46.json.sig")
        shutil.copy(root / "t46.commands.txt", altered_log / "t46.commands.txt")
        (altered_log / "t46.dmesg.log").write_text("[ 0.0 ] tampered evidence\n")
        leg("rejects an altered decisive log", "decisive-log-mismatch",
            _args(**{**vars(accept), "receipt": str(altered_log / "t46.json"), "seen_db": None}))

        altered_manifest = root / "altered-manifest"
        altered_manifest.mkdir()
        shutil.copy(receipt, altered_manifest / "t46.json")
        shutil.copy(root / "t46.json.sig", altered_manifest / "t46.json.sig")
        shutil.copy(root / "t46.dmesg.log", altered_manifest / "t46.dmesg.log")
        (altered_manifest / "t46.commands.txt").write_text("sudo rm -rf /\n")
        leg("rejects an altered command manifest", "command-manifest-mismatch",
            _args(**{**vars(accept), "receipt": str(altered_manifest / "t46.json"), "seen_db": None}))

    if failures:
        print(f"verify-hardware-receipt self-test: FAIL ({failures} leg(s))", file=sys.stderr)
        return 1
    print("verify-hardware-receipt self-test: PASS (1 accept + 11 distinct rejections)")
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--receipt")
    parser.add_argument("--pubkey")
    parser.add_argument("--signature")
    parser.add_argument("--evidence-root")
    parser.add_argument("--expect-key-fingerprint")
    parser.add_argument("--target")
    parser.add_argument("--todo", type=int)
    parser.add_argument("--build-mode")
    parser.add_argument("--expect-artifact", action="append", default=[], metavar="KEY=VALUE")
    parser.add_argument("--command-manifest")
    parser.add_argument("--require", action="append", default=[], metavar="MARKER")
    parser.add_argument("--seen-db")
    parser.add_argument("--canonicalize", metavar="FILE",
                        help="rewrite FILE in place as RFC 8785 canonical JSON and exit")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args(argv)

    if args.self_test:
        return self_test()
    if args.canonicalize:
        path = Path(args.canonicalize)
        path.write_bytes(canonical_bytes(json.loads(path.read_text())))
        return 0
    if not args.receipt or not args.pubkey:
        parser.error("--receipt and --pubkey are required")

    required: list[str] = []
    for entry in args.require:
        required.extend(part for part in entry.split(",") if part)
    args.require = required

    try:
        verify(args)
    except ReceiptError as exc:
        print(f"RECEIPT REJECTED [{exc.code}] {exc.detail}", file=sys.stderr)
        return 1
    print(f"RECEIPT ACCEPTED {args.receipt} target={args.target or '(unchecked)'}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
