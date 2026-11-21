#!/usr/bin/env python3
"""Real local HTTPS/mTLS and archive signatures; no external connections or credentials."""

from contextlib import contextmanager, nullcontext, redirect_stderr, redirect_stdout
from collections.abc import Iterator
from copy import deepcopy
from dataclasses import asdict
from datetime import datetime, timedelta, timezone
from email.utils import format_datetime, parsedate_to_datetime
import gzip
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import io
import json
import lzma
import os
from pathlib import Path
import runpy
import shlex
import shutil
import ssl
import stat
import subprocess
import sys
import tarfile
import tempfile
import threading
from functools import partial
from unittest.mock import patch

from capsule_transport_fixture import IDENTITY, PUBLIC, PUBLIC_V6, fixture_dns
from sealed_inputs_test import deb

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "ci/kernel-runner"))
from image_capsule import unpack
from image_stream import Identity
from image_stream import StreamError
from image_transport import copy_local, identity_config


LOCAL_PATH_CANARY = "private-client-key-path-canary"

CANDIDATE_KIND = "measurement-candidate"
CANDIDATE_META = ("kernel-artifact.json", "resolved.config", "built-modules.txt", "SHA256SUMS")
CANDIDATE_PROOF = ("candidate.json", "publish-authorization.inputs.json", "BUNDLE.SHA256SUMS")
LOCAL_STATUS = {"publication": "local-unpublishable", "kernel_floor": "skipped-local",
                "github_release_history": "skipped-local"}
INVALID_ARTIFACT_STATUS = (
    ("publication", ("published", False, "local-unpublishable ")),
    ("kernel_floor", ("none", 0, "skipped-loca")),
    ("github_release_history", ("checked-remote", ["skipped-local"], "checked-local-snapsho")),
)


def test_candidate_sealing_binds_the_exact_private_producer_bundle() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        work = Path(temporary)
        bundle = work / LOCAL_PATH_CANARY
        version = "7.2.0-ceralive9"
        package = "linux-image-7.2.0-ceralive-rk3588"
        deb_name = f"{package}_{version}_arm64.deb"
        payloads = (deb_name, *CANDIDATE_META)
        producer = subprocess.check_output(
            ["git", "-C", str(ROOT), "rev-parse", "--verify", "HEAD^{commit}"],
            env=os.environ | {"GIT_MASTER": "1", "GIT_NO_LAZY_FETCH": "1"}, text=True, timeout=10,
        ).strip()
        subprocess.run([
            "bash", "-euo", "pipefail", "-c",
            'ROOT="$1"; WORK="$2"; source "$ROOT/tests/lib/kernel-release-fixtures.sh"; '
            'kernel_test_artifact "$3" "$4" "$ROOT"',
            "_", str(ROOT), temporary, str(bundle), version,
        ], capture_output=True, check=True, timeout=30)

        def pin(data: bytes) -> dict[str, str | int]:
            return {"sha256": hashlib.sha256(data).hexdigest(), "length": len(data)}

        def sums(files: dict[str, bytes]) -> bytes:
            return "".join(f"{pin(data)['sha256']}  {name}\n" for name, data in sorted(files.items())).encode()

        content = {name: (bundle / name).read_bytes() for name in payloads}
        metadata = json.loads(content["kernel-artifact.json"])
        receipt = {"schema": 1, "family": "rk3588", "commit": producer, "candidate_run_id": "123",
                   "kernel_floor": "none", "publication": "blocked-pending-owner"}
        authorization = {
            "mode": "apt-publish", "publish_run_id": None, "run_attempt": None, "candidate_run_id": "123",
            "tag": f"kernel/v{version}", "commit": producer, "package": package, "version": version,
            "deb_sha256": pin(content[deb_name])["sha256"], "channel": "stable", "bench_report_sha256": None,
        }

        def proof(candidate: dict, auth: dict, files: dict[str, bytes]) -> dict[str, bytes]:
            records = {"candidate.json": json.dumps(candidate).encode(),
                       "publish-authorization.inputs.json": json.dumps(auth).encode()}
            return records | {"BUNDLE.SHA256SUMS": sums(files | records)}

        original = content | proof(receipt, authorization, content)
        for name, data in original.items():
            path = bundle / name
            path.write_bytes(data)
            path.chmod(0o600)
        binding = {
            "package": package, "version": version, "arch": "arm64",
            "validated_boards": metadata["validated_boards"], "input_fingerprint": metadata["input_fingerprint"],
            "producer_commit": producer, "candidate_run_id": "123",
            "payloads": {name: pin(original[name]) for name in payloads},
            "proof": {name: pin(original[name]) for name in CANDIDATE_PROOF},
        }
        rows, remote = [], {}

        def object_row(data: bytes, kind: str, url: str = "") -> str:
            row = pin(data) | {"kind": kind, "urls": [url] if url else []}
            digest = str(row["sha256"])
            if url:
                remote[url] = data
            else:
                (work / digest).write_bytes(data)
                row["path"] = digest
            rows.append(row)
            return digest

        source = object_row(b"source", "source-bundle")
        device = object_row(b"root", "public-trust")
        keyring = object_row(b"keyring", "apt-metadata")
        builder = object_row(b"builder", "builder-image")
        archives, repositories = {}, {}
        for name, origin in (("firstparty", "https://apt.ceralive.tv"), ("bsp", "https://repo.example"),
                             ("debian-source", "https://deb.debian.org/debian")):
            base = origin + "/dists/stable" + ("/binary-arm64" if name == "firstparty" else "")
            repo = {"origin": origin, "keyring": keyring, "fingerprints": ["A" * 40], "suite": "stable",
                    "component": "main", "arch": "arm64", "index_path": "Packages.gz"}
            archives[name] = repo | {"max_age_seconds": 86400}
            repositories[name] = repo | {
                "inrelease": object_row(name.encode() + b" release", "apt-metadata", base + "/InRelease"),
                "index": object_row(name.encode() + b" index", "apt-metadata", base + "/Packages.gz"),
            }
        filename = "ceralive-device_1_arm64.deb"
        userspace = b"already authenticated userspace fixture"
        package_digest = object_row(userspace, "deb", f"https://apt.ceralive.tv/dists/stable/binary-arm64/{filename}")
        field = "measurement_candidate"
        policy = {"schema": 1, "root_der_sha256": "1" * 64, "repositories": archives,
                  "builder_images": [{"object": builder, "tag": "fixture", "arch": "arm64",
                                      "image_id": "sha256:" + "3" * 64}], field: binding}
        reviewed = {"schema": 1, "source_commit": "a" * 40, "epoch": 1234, "board": "rock-5b-plus",
                    "source_bundle": source, "device_root": device, "objects": rows, "repositories": repositories,
                    "packages": [{"repository": "firstparty", "name": "ceralive-device", "version": "1",
                                  "arch": "arm64", "sha256": package_digest}], field: {"bundle": bundle.name}}
        inventory, trust, output = (work / name for name in ("reviewed.json", "policy.json", "capsule.tar"))
        cli = ROOT / "ci/prepare-image-capsule.py"
        argv = [str(cli), "--inventory", str(inventory), "--trust-policy", str(trust), "--output", str(output)]
        requests = []

        def fetch_bytes(url: str, target: Path, *_args: object) -> None:
            requests.append(url)
            target.write_bytes(remote[url])

        def offline_shell(script: str, *_args: object) -> str:
            if "auth_lookup_package" in script:
                return f"{filename}\t{package_digest}\t1\tarm64\t{len(userspace)}"
            assert "rauc_public_root_resolve" in script or "assert_deb_identity" in script
            return ""

        def validity(directory: Path) -> tuple:
            (directory / "metadata-validity.json").write_text("{}")
            return ()

        def invoke(selected: dict = binding, inventory_row: dict = reviewed, *,
                   raw_policy: str = "") -> tuple[int, str]:
            inventory.write_text(json.dumps(inventory_row))
            trust.write_text(raw_policy or json.dumps(policy | {field: selected}))
            requests.clear()
            stderr = io.StringIO()
            with patch.object(sys, "argv", argv), patch("image_transport.fetch", side_effect=fetch_bytes), \
                    patch("image_transport.shell", side_effect=offline_shell), \
                    patch.dict("image_transport.SEALED", {"mirror_validities": validity,
                                                         "decompress_index": lambda *_args: None}), \
                    redirect_stderr(stderr), redirect_stdout(io.StringIO()):
                try:
                    runpy.run_path(str(cli), run_name="__main__")
                except SystemExit as exc:
                    return exc.code, stderr.getvalue()
            return 0, stderr.getvalue()

        failures = []

        def rejected(label: str, expected: str, selected: dict = binding, inventory_row: dict = reviewed, *,
                     raw_policy: str = "") -> None:
            rc, error = invoke(selected, inventory_row, raw_policy=raw_policy)
            assert not output.exists() and not list(work.glob(".prefetch-*")), label
            assert not requests, (label, requests)
            assert all(marker not in error for marker in ("/", "://", LOCAL_PATH_CANARY, "password-canary")), error
            if rc != 1 or expected not in error:
                failures.append((label, expected, rc, error.strip()))

        for key in binding:
            rejected(f"drop {key}", "measurement-candidate policy", {k: v for k, v in binding.items() if k != key})
            rejected(f"wrong type {key}", "measurement-candidate policy", binding | {key: True})
            raw = json.dumps(policy).replace(f'"{key}":', f'"{key}": null, "{key}":', 1)
            rejected(f"duplicate {key}", "duplicate JSON key", raw_policy=raw)
        for key, changed in (("package", "linux-image-7.3.0-ceralive-rk3588"), ("version", "7.2.0-ceralive8"),
                             ("arch", "amd64"), ("validated_boards", ["rock-5b-plus"]),
                             ("input_fingerprint", "4" * 64), ("producer_commit", "5" * 40),
                             ("candidate_run_id", "456")):
            diagnostic = {
                "package": "policy identity", "version": "policy file closure",
                "arch": "policy identity", "validated_boards": "policy identity",
                "input_fingerprint": "artifact fingerprint mismatch", "producer_commit": "producer commit",
                "candidate_run_id": "producer run",
            }[key]
            rejected(f"change {key}", diagnostic, binding | {key: changed})
        rejected("whole inventory binding omitted", "measurement-candidate inventory",
                 inventory_row={k: v for k, v in reviewed.items() if k != field})
        rejected("whole policy binding omitted", "measurement-candidate",
                 raw_policy=json.dumps({k: v for k, v in policy.items() if k != field}))
        rejected("second candidate policy", "measurement-candidate policy", [binding, binding])
        rejected("second candidate inventory", "measurement-candidate inventory",
                 inventory_row=reviewed | {field: [reviewed[field], reviewed[field]]})
        rejected("extra field in inventory selection", "measurement-candidate inventory",
                 inventory_row=reviewed | {field: reviewed[field] | {"commit": producer}})
        rejected("URL-bearing typed object", "measurement-candidate inventory",
                 inventory_row=reviewed | {"objects": rows + [pin(b"extra") | {
                     "kind": CANDIDATE_KIND, "urls": ["https://invalid.example/password-canary"]}]})
        rejected("unbound released metadata", "measurement-candidate inventory",
                 inventory_row=reviewed | {"objects": rows + [pin(b"legacy") | {
                     "kind": "kernel-metadata", "urls": [], "path": "legacy"}]})
        rejected("second signed APT kernel", "measurement-candidate inventory cannot also seal an APT kernel",
                 inventory_row=reviewed | {"packages": [reviewed["packages"][0] | {"name": package}]})
        rejected("another capsule object with the producer receipt digest", "inventory reuses a private bundle object",
                 inventory_row=reviewed | {"objects": rows + [pin(original["candidate.json"]) | {
                     "kind": "public-trust", "urls": [], "path": "private-proof"}]})
        rejected("unrelated board", "invalid host-selected identity", inventory_row=reviewed | {"board": "x86-minipc"})
        rejected("released and candidate approval together", "invalid public trust policy fields",
                 raw_policy=json.dumps(policy | {"kernel_metadata": {}}))
        for name in (*payloads, *CANDIDATE_PROOF):
            group = "payloads" if name in payloads else "proof"
            pins = binding[group]
            rejected(f"omit pin for {name}", "measurement-candidate policy",
                     binding | {group: {k: v for k, v in pins.items() if k != name}})
            for leaf, invalid in (("sha256", True), ("length", True)):
                rejected(f"wrong {leaf} type for {name}", "measurement-candidate policy",
                         binding | {group: pins | {name: pins[name] | {leaf: invalid}}})
                rejected(f"omit {leaf} for {name}", "measurement-candidate policy",
                         binding | {group: pins | {name: {k: v for k, v in pins[name].items() if k != leaf}}})
                selected_pin = json.dumps(pins[name])
                duplicate_pin = selected_pin.replace(f'"{leaf}":', f'"{leaf}": null, "{leaf}":', 1)
                rejected(f"duplicate {leaf} for {name}", "duplicate JSON key",
                         raw_policy=json.dumps(policy).replace(selected_pin, duplicate_pin, 1))
            duplicate_object = f'{json.dumps(name)}: {json.dumps(pins[name])}'
            rejected(f"duplicate {name}", "duplicate JSON key",
                     raw_policy=json.dumps(policy).replace(duplicate_object, duplicate_object + ", " + duplicate_object, 1))
            rejected(f"wrong pinned hash for {name}", "SHA-256 (first 16) pinned=" + "4" * 16,
                     binding | {group: pins | {name: pins[name] | {"sha256": "4" * 64}}})
            rejected(f"wrong pinned length for {name}",
                     f"size (bytes) pinned={len(original[name]) + 1} observed={len(original[name])}",
                     binding | {group: pins | {name: pins[name] | {"length": len(original[name]) + 1}}})
            path = bundle / name
            link_target = work / "password-canary-file"
            link_target.write_bytes(original[name])
            for shape in ("missing", "wrong size", "tampered", "symlink", "fifo"):
                path.unlink()
                if shape == "wrong size":
                    path.write_bytes(original[name] + b"x")
                elif shape == "tampered":
                    path.write_bytes(b"x" * len(original[name]))
                elif shape == "symlink":
                    path.symlink_to(link_target)
                elif shape == "fifo":
                    os.mkfifo(path)
                try:
                    diagnostic = f"size (bytes) pinned={len(original[name])} observed=unavailable"
                    if shape == "tampered":
                        diagnostic = (f"SHA-256 (first 16) pinned={pins[name]['sha256'][:16]} "
                                      f"observed={pin(b'x' * len(original[name]))['sha256'][:16]}")
                    elif shape == "wrong size":
                        diagnostic = f"size (bytes) pinned={len(original[name])} observed={len(original[name]) + 1}"
                    rejected(f"{shape} at {name}", diagnostic)
                finally:
                    path.unlink(missing_ok=True)
                    path.write_bytes(original[name])
                    path.chmod(0o600)
        extra = bundle / "password-canary.deb"
        extra.write_bytes(b"sixth payload")
        rejected("extra sixth payload", "measurement-candidate bundle closure")
        extra.unlink()

        def coherently_replace(label: str, files: dict[str, bytes], evidence: dict[str, bytes],
                               expected: str, **changes: object) -> None:
            for name, data in (files | evidence).items():
                (bundle / name).write_bytes(data)
            try:
                rejected(label, expected, binding | {"payloads": {k: pin(v) for k, v in files.items()},
                                                     "proof": {k: pin(v) for k, v in evidence.items()}} | changes)
            finally:
                for name, data in original.items():
                    (bundle / name).write_bytes(data)

        coherently_replace("other producer commit", content, proof(receipt | {"commit": "6" * 40}, authorization, content),
                           "producer commit")
        coherently_replace("other producer package", content, proof(receipt, authorization | {"package": "other"}, content),
                           "producer package")
        coherently_replace("other producer run", content, proof(receipt | {"candidate_run_id": "456"}, authorization, content),
                           "producer run")
        coherently_replace("other producer version", content, proof(receipt, authorization | {"version": "other"}, content),
                           "producer version")
        coherently_replace("other producer tag", content, proof(receipt, authorization | {"tag": "other"}, content),
                           "producer tag")
        coherently_replace("other producer deb", content, proof(receipt, authorization | {"deb_sha256": "7" * 64}, content),
                           "producer deb digest")
        coherently_replace("producer is already published", content,
                           proof(receipt | {"publication": "published"}, authorization, content), "producer receipt state")
        local_payload = content | {"kernel-artifact.json": json.dumps(metadata | LOCAL_STATUS).encode()}
        local_payload["SHA256SUMS"] = sums({k: v for k, v in local_payload.items() if k != "SHA256SUMS"})
        local_receipt = receipt | LOCAL_STATUS
        local_auth = authorization | {"mode": "local-unpublishable"}
        local_proof = proof(local_receipt, local_auth, local_payload)
        from kernel_release import KernelReleaseError, verified_metadata

        guest_stage = runpy.run_path(str(ROOT / "lib/measurement-candidate.py"))["stage"]
        guest_identity = Identity("fixture", reviewed["board"], reviewed["source_commit"], reviewed["epoch"], "a" * 64)
        for status_field, invalid_values in INVALID_ARTIFACT_STATUS:
            for invalid_value in invalid_values:
                label = f"artifact marker {status_field}={invalid_value!r}"
                changed = LOCAL_STATUS | {status_field: invalid_value}
                files = local_payload | {"kernel-artifact.json": json.dumps(metadata | changed).encode()}
                files["SHA256SUMS"] = sums({name: data for name, data in files.items() if name != "SHA256SUMS"})
                evidence = proof(local_receipt | changed, local_auth | {"mode": changed["publication"]}, files)
                with tempfile.TemporaryDirectory(dir=work) as directory:
                    guest = Path(directory)
                    inputs = guest / "inputs"
                    inputs.mkdir(mode=0o700)
                    for name, data in files.items():
                        for path in (guest / name, inputs / pin(data)["sha256"]):
                            path.touch(mode=0o600, exist_ok=False)
                            path.write_bytes(data)
                    try:
                        verified_metadata(version, guest, measurement=True)
                    except KernelReleaseError as error:
                        assert str(error) == "invalid local candidate metadata status", (label, error)
                    else:
                        failures.append(f"library accepted invalid {label}")
                    guest_pins = {name: pin(data) for name, data in files.items()}
                    approval = binding | {"payloads": guest_pins, "proof": {k: pin(v) for k, v in evidence.items()}}
                    guest_trust = {field: approval}
                    guest_objects = [row | {"kind": CANDIDATE_KIND, "urls": []} for row in guest_pins.values()]
                    guest_inventory = {key: reviewed[key] for key in ("board", "source_commit", "epoch")}
                    job = guest / "job.json"
                    for path, record in (
                        (inputs / "trust.json", guest_trust),
                        (inputs / "inventory.json", guest_inventory | {field: approval, "objects": guest_objects}),
                        (job, {"schema": 1, "operation": "verify", "identity": asdict(guest_identity), "trust": guest_trust}),
                    ):
                        path.touch(mode=0o600, exist_ok=False)
                        path.write_text(json.dumps(record))
                    output_dir = guest / "staged"
                    with patch.dict(os.environ, {"CERALIVE_BUILD_PURPOSE": "rootfs-measurement"}), \
                            patch.dict(guest_stage.__globals__, {"JOB": job, "INPUTS": inputs}):
                        try:
                            guest_stage(inputs, reviewed["board"], (package, version, "arm64"), output_dir)
                        except StreamError as error:
                            assert str(error) == "invalid measurement-candidate payload checksum or metadata", (label, error)
                            assert not output_dir.exists(), label
                        else:
                            failures.append(f"guest staged invalid {label}")
                try:
                    coherently_replace(f"sealer {label}", files, evidence, "artifact status")
                except AssertionError as error:
                    failures.append(f"sealer did not reject {label} before prefetch: {error}")
                finally:
                    output.unlink(missing_ok=True)
        for status_field in LOCAL_STATUS:
            for value in ("unexpected", False):
                coherently_replace(f"invalid local receipt {status_field}={value!r}", local_payload,
                                   proof(local_receipt | {status_field: value}, local_auth, local_payload),
                                   "producer receipt state")
            reduced = {k: v for k, v in local_receipt.items() if k != status_field}
            coherently_replace(f"missing local receipt {status_field}", local_payload,
                               proof(reduced, local_auth, local_payload), "producer receipt record")
            dup = local_proof["candidate.json"].replace(f'"{status_field}":'.encode(),
                                                       f'"{status_field}": null, "{status_field}":'.encode(), 1)
            records = {"candidate.json": dup, "publish-authorization.inputs.json": local_proof["publish-authorization.inputs.json"]}
            coherently_replace(f"duplicate local receipt {status_field}", local_payload,
                               records | {"BUNDLE.SHA256SUMS": sums(local_payload | records)},
                               "producer receipt record")
            bad_metadata = {key: value for key, value in (metadata | LOCAL_STATUS).items() if key != status_field}
            bad_payload = local_payload | {"kernel-artifact.json": json.dumps(bad_metadata).encode()}
            bad_payload["SHA256SUMS"] = sums({k: v for k, v in bad_payload.items() if k != "SHA256SUMS"})
            coherently_replace(f"missing artifact status {status_field}", bad_payload,
                               proof(local_receipt, local_auth, bad_payload), "artifact status")
        coherently_replace("local candidate with normal auth mode", local_payload,
                           proof(local_receipt, authorization, local_payload), "producer receipt state")
        coherently_replace("local candidate with no artifact status", content,
                           proof(local_receipt, local_auth, content), "producer receipt record")
        for name, data in (local_payload | local_proof).items():
            (bundle / name).write_bytes(data)
            (bundle / name).chmod(0o600)
        local_binding = binding | {"payloads": {k: pin(v) for k, v in local_payload.items()},
                                   "proof": {k: pin(v) for k, v in local_proof.items()}}
        rc, diagnostic = invoke(local_binding)
        assert rc == 0 and output.is_file(), diagnostic
        with tarfile.open(output) as archive:
            kernel_meta = local_binding["payloads"]["kernel-artifact.json"]["sha256"]
            sealed = json.load(archive.extractfile("objects/" + kernel_meta))
            assert {key: sealed[key] for key in LOCAL_STATUS} == LOCAL_STATUS
        output.unlink()
        for name, data in original.items():
            (bundle / name).write_bytes(data)
        coherently_replace("missing commit in producer receipt", content,
                           proof({k: v for k, v in receipt.items() if k != "commit"}, authorization, content),
                           "producer receipt record")
        coherently_replace("non-string commit in producer receipt", content,
                           proof(receipt | {"commit": True}, authorization, content), "producer commit")
        other = proof(receipt, authorization, content)
        other["BUNDLE.SHA256SUMS"] = other["BUNDLE.SHA256SUMS"].replace(
            str(pin(content[deb_name])["sha256"]).encode(), b"7" * 64)
        coherently_replace("different envelope hash", content, other, "checksum envelope mismatch")
        other = proof(receipt, authorization, content)
        other["BUNDLE.SHA256SUMS"] = b"\n".join(other["BUNDLE.SHA256SUMS"].splitlines()[1:]) + b"\n"
        coherently_replace("missing producer envelope entry", content, other, "checksum envelope coverage")
        coherently_replace("second checksum entry", content,
                           {name: original[name] for name in CANDIDATE_PROOF} | {
                               "BUNDLE.SHA256SUMS": original["BUNDLE.SHA256SUMS"] * 2}, "checksum envelope")
        changed = content | {"kernel-artifact.json": json.dumps(metadata | {"input_fingerprint": "4" * 64}).encode()}
        changed["SHA256SUMS"] = sums({k: v for k, v in changed.items() if k != "SHA256SUMS"})
        coherently_replace("wrong recomputed fingerprint", changed, proof(receipt, authorization, changed),
                           "family fingerprint", input_fingerprint="4" * 64)
        coherently_replace("producer fingerprint differs from policy", changed, proof(receipt, authorization, changed),
                           "artifact fingerprint mismatch")
        changed = content | {"kernel-artifact.json": json.dumps(
            metadata | {"validated_boards": ["rock-5b-plus"]}).encode()}
        changed["SHA256SUMS"] = sums({k: v for k, v in changed.items() if k != "SHA256SUMS"})
        coherently_replace("producer omits both-board evidence", changed, proof(receipt, authorization, changed),
                           "both-board validation")
        changed = content | {"SHA256SUMS": sums({k: v for k, v in content.items() if k != "SHA256SUMS"}) * 2}
        coherently_replace("duplicate payload checksum", changed, proof(receipt, authorization, changed),
                           "payload checksum or metadata")
        wrong_deb = deb("9.0", "amd64")
        wrong_deb_hash = pin(wrong_deb)["sha256"]
        changed = content | {deb_name: wrong_deb, "kernel-artifact.json": json.dumps(
            metadata | {"deb_sha256": wrong_deb_hash}).encode()}
        changed["SHA256SUMS"] = sums({k: v for k, v in changed.items() if k != "SHA256SUMS"})
        coherently_replace("deb control differs despite all matching hashes", changed,
                           proof(receipt, authorization | {"deb_sha256": wrong_deb_hash}, changed),
                           "deb control identity")

        unpacked = work / "unpacked-kernel"
        subprocess.run(["dpkg-deb", "-R", str(bundle / deb_name), str(unpacked)],
                       capture_output=True, check=True, timeout=30)
        for board, dtb_name in (("orange-pi-5-plus", "rk3588-orangepi-5-plus.dtb"),
                                ("rock-5b-plus", "rk3588-rock-5b-plus.dtb")):
            dtb, = unpacked.rglob(dtb_name)
            payload = dtb.read_bytes()
            dtb.unlink()
            repacked = work / "repacked.deb"
            try:
                subprocess.run(["dpkg-deb", "--root-owner-group", "--build", str(unpacked), str(repacked)],
                               capture_output=True, check=True, timeout=30)
                changed = content | {deb_name: repacked.read_bytes()}
            finally:
                dtb.write_bytes(payload)
            deb_hash = pin(changed[deb_name])["sha256"]
            changed["kernel-artifact.json"] = json.dumps(metadata | {"deb_sha256": deb_hash}).encode()
            changed["SHA256SUMS"] = sums({k: v for k, v in changed.items() if k != "SHA256SUMS"})
            coherently_replace(f"deb missing DTB for {board}", changed,
                               proof(receipt, authorization | {"deb_sha256": deb_hash}, changed),
                               f"kernel deb board check failed: {board}; DTB presence pinned=present observed=unverified")

        absent_commit = "f" * 40
        coherently_replace("producer commit not in local repository", content,
                           proof(receipt | {"commit": absent_commit}, authorization | {"commit": absent_commit}, content),
                           "producer commit is not a local commit", producer_commit=absent_commit)

        def deb_evidence(data: bytes) -> tuple[dict[str, bytes], dict[str, bytes]]:
            digest = pin(data)["sha256"]
            files = content | {deb_name: data, "kernel-artifact.json": json.dumps(
                metadata | {"deb_sha256": digest}).encode()}
            files["SHA256SUMS"] = sums({k: v for k, v in files.items() if k != "SHA256SUMS"})
            return files, proof(receipt, authorization | {"deb_sha256": digest}, files)

        def repinned_deb(label: str, data: bytes, diagnostic: str) -> None:
            files, evidence = deb_evidence(data)
            coherently_replace(label, files, evidence, diagnostic)

        fixture_deb = bundle / deb_name
        data_tar = subprocess.check_output(["dpkg-deb", "--fsys-tarfile", str(fixture_deb)], timeout=30)
        ar_names = subprocess.check_output(["ar", "t", str(fixture_deb)], text=True, timeout=30).splitlines()
        control_name, = (name for name in ar_names if name.startswith("control.tar"))
        for name in ("debian-binary", control_name):
            (work / name).write_bytes(subprocess.check_output(["ar", "p", str(fixture_deb), name], timeout=30))
        archive_canary = "password-canary"
        with tarfile.open(fileobj=io.BytesIO(data_tar)) as source:
            dtbs = {board: next(member.name for member in source.getmembers() if member.name.endswith("/" + name))
                    for board, name in (("orange-pi-5-plus", "rk3588-orangepi-5-plus.dtb"),
                                        ("rock-5b-plus", "rk3588-rock-5b-plus.dtb"))}

        def changed_deb(board: str, shape: str) -> bytes:
            target = dtbs[board]
            other = next(name for name in dtbs.values() if name != target)
            data = io.BytesIO()
            with tarfile.open(fileobj=io.BytesIO(data_tar)) as source, tarfile.open(
                    fileobj=data, mode="w", format=tarfile.PAX_FORMAT if shape == "pax" else tarfile.GNU_FORMAT
            ) as destination:
                for member in source:
                    if member.name == target and shape in {"fifo", "symlink", "hardlink", "directory", "device"}:
                        replacement = tarfile.TarInfo(target)
                        replacement.type = {
                            "fifo": tarfile.FIFOTYPE, "symlink": tarfile.SYMTYPE, "hardlink": tarfile.LNKTYPE,
                            "directory": tarfile.DIRTYPE, "device": tarfile.CHRTYPE,
                        }[shape]
                        if shape in {"symlink", "hardlink"}:
                            replacement.linkname = Path(other).name if shape == "symlink" else other
                        destination.addfile(replacement)
                    elif shape == "ancestor" and member.name == target.rsplit("/", 1)[0]:
                        replacement = tarfile.TarInfo(member.name)
                        replacement.type = tarfile.SYMTYPE
                        replacement.linkname = archive_canary
                        destination.addfile(replacement)
                    else:
                        destination.addfile(member, source.extractfile(member) if member.isfile() else None)
                if shape in {"duplicate", "duplicate-alias", "absolute", "parent", "pax", "sparse",
                             "long-protected", "long-unrelated"}:
                    name = target.removeprefix("./")
                    added = tarfile.TarInfo({
                        "duplicate": target, "long-protected": "./" + "x" * 110 + "/../" + name,
                        "long-unrelated": "./usr/lib/modules/" + "x" * 110,
                        "absolute": "/" + name, "parent": f"./{archive_canary}/../{name}",
                    }.get(shape, name))
                    if shape == "pax":
                        added.pax_headers = {"path": name}
                    if shape == "sparse":
                        added.type = tarfile.GNUTYPE_SPARSE
                    destination.addfile(added)
            trailer = b"password-canary".ljust(tarfile.BLOCKSIZE, b"\0") if shape == "trailer" else b""
            (work / "data.tar.xz").write_bytes(lzma.compress(data.getvalue() + trailer))
            repacked = work / "archive-shape.deb"
            repacked.unlink(missing_ok=True)
            subprocess.run(["ar", "rc", repacked.name, "debian-binary", control_name, "data.tar.xz"], cwd=work,
                           capture_output=True, check=True, timeout=30)
            return repacked.read_bytes()

        for board in dtbs:
            for shape in ("fifo", "symlink"):
                repinned_deb(f"deb DTB {shape} for {board}", changed_deb(board, shape),
                             f"{board}; DTB member pinned=regular observed={shape}")
        board = "orange-pi-5-plus"
        for shape, diagnostic in (
            ("hardlink", f"{board}; DTB member pinned=regular observed=hardlink"),
            ("directory", f"{board}; DTB member pinned=regular observed=directory"),
            ("device", f"{board}; DTB member pinned=regular observed=device"),
            ("duplicate", f"{board}; DTB member pinned=regular observed=duplicate"),
            ("duplicate-alias", f"{board}; DTB member pinned=regular observed=duplicate"),
            ("absolute", f"{board}; DTB member pinned=regular observed=non-canonical"),
            ("parent", f"{board}; DTB member pinned=regular observed=non-canonical"),
            ("long-protected", f"{board}; DTB member pinned=regular observed=non-canonical"),
            ("ancestor", "DTB member pinned=regular observed=non-directory ancestor"),
            ("pax", "kernel deb data archive rejected: pax header"),
            ("sparse", "kernel deb data archive rejected: sparse header"),
            ("trailer", "kernel deb data archive rejected: nonzero trailer"),
        ):
            repinned_deb(f"deb DTB {shape} for {board}", changed_deb(board, shape), diagnostic)

        files, evidence = deb_evidence(changed_deb(board, "long-unrelated"))
        try:
            for name, payload in (files | evidence).items():
                (bundle / name).write_bytes(payload)
            extended_binding = binding | {"payloads": {k: pin(v) for k, v in files.items()},
                                          "proof": {k: pin(v) for k, v in evidence.items()}}
            rc, error = invoke(extended_binding)
            assert rc == 0 and output.is_file(), error
        finally:
            output.unlink(missing_ok=True)
            for name, payload in original.items():
                (bundle / name).write_bytes(payload)

        rc, error = invoke()
        if rc != 0:
            failures.append(("valid reviewed producer bundle", "successful seal", rc, error.strip()))
        assert not failures, "\n".join(map(str, failures))
        with tarfile.open(output, "r:") as archive:
            stream = archive.extractfile("inventory.json")
            assert stream is not None
            sealed = json.load(stream)
            assert sealed[field] == binding
            candidate_rows = [row for row in sealed["objects"] if row["kind"] == CANDIDATE_KIND]
            assert sorted(candidate_rows, key=lambda row: row["sha256"]) == sorted(
                [pin(original[name]) | {"kind": CANDIDATE_KIND, "urls": []} for name in payloads],
                key=lambda row: row["sha256"]), "unexpected candidate object closure"
            for name in payloads:
                stream = archive.extractfile("objects/" + str(pin(original[name])["sha256"]))
                assert stream is not None and stream.read() == original[name]
            for name in CANDIDATE_PROOF:
                assert "objects/" + str(pin(original[name])["sha256"]) not in archive.getnames()
            assert not any(row.get("path") for row in sealed["objects"])
        try:
            from image_policy import load_policy
            load_policy(trust)
        except StreamError:
            pass
        else:
            raise AssertionError("launcher loaded a host-only candidate policy")
        try:
            unpack(output, work / "runtime", Identity("fixture", reviewed["board"], reviewed["source_commit"],
                   reviewed["epoch"], hashlib.sha256(output.read_bytes()).hexdigest()))
        except StreamError:
            pass
        else:
            raise AssertionError("runtime accepted a host-only candidate capsule")


def assert_mismatch_line(diagnostic: str, label: str, pinned_size: int, observed_size: int,
                         pinned_hash: str, observed_hash: str) -> None:
    prefix = "capsule preparation rejected: prefetched object size or digest mismatch"
    assert diagnostic.startswith(prefix), diagnostic
    for marker in ("/", "://", "?", "@", "deb.debian.org", "apt.ceralive.tv",
                   "token-canary", "client-key-canary", "password-canary", "Bearer secret",
                   LOCAL_PATH_CANARY, pinned_hash, observed_hash):
        assert marker not in diagnostic, (marker, diagnostic)
    assert diagnostic == (f"{prefix}: {label}; size (bytes) pinned={pinned_size} observed={observed_size}; "
                          f"SHA-256 (first 16) pinned={pinned_hash[:16]} observed={observed_hash[:16]}\n"), diagnostic


def assert_prefetch_mismatch(repository: str | None, role: str, label: str, *, size_only: bool = False) -> None:
    """Exercise the producer CLI with real inventory validation and inert transport bytes."""
    with tempfile.TemporaryDirectory(prefix="capsule-mismatch-") as temporary:
        work = Path(temporary)
        private = work / LOCAL_PATH_CANARY
        private.mkdir()
        objects = []
        responses: dict[str, bytes] = {}

        def store(payload: bytes, kind: str, url: str = "") -> str:
            digest = hashlib.sha256(payload).hexdigest()
            row = {"sha256": digest, "length": len(payload), "kind": kind, "urls": [url] if url else []}
            if url:
                responses[url] = payload
            else:
                path = private / ("client-key-canary-" + digest)
                path.write_bytes(payload)
                row["path"] = str(path)
            objects.append(row)
            return digest

        source = store(b"source bundle fixture", "source-bundle")
        root = store(b"public root fixture", "public-trust")
        keyring = store(b"archive keyring fixture", "apt-metadata")
        builder = store(b"builder fixture", "builder-image")
        kernel = {name: store(b"{}" if name == "kernel-artifact.json" else name.encode(), "kernel-metadata") for name in
                  ("kernel-artifact.json", "resolved.config", "built-modules.txt", "SHA256SUMS")}
        policies = {}
        repositories = {}
        for name, origin in (("firstparty", "https://apt.ceralive.tv"),
                             ("bsp", "https://repo.example"),
                             ("debian-source", "https://deb.debian.org/debian"),
                             ("debian-security", "https://deb.debian.org/debian-security")):
            suite = "stable-security" if name == "debian-security" else "stable"
            base = f"{origin}/dists/{suite}" + ("/binary-arm64" if name == "firstparty" else "")
            index_path = "token-canary/Packages.gz"
            repo = {"origin": origin, "keyring": keyring, "fingerprints": ["A" * 40],
                    "suite": suite, "component": "main", "arch": "arm64", "index_path": index_path}
            policies[name] = repo | {"max_age_seconds": 86400}
            repositories[name] = repo | {
                "inrelease": store(f"{name} release".encode(), "apt-metadata", f"{base}/InRelease"),
                "index": store(f"{name} index".encode(), "apt-metadata", f"{base}/{index_path}"),
            }
        package = store(b"package fixture", "deb", "https://apt.ceralive.tv/fixture.deb")
        reviewed = {"schema": 1, "source_commit": "a" * 40, "epoch": 1234, "board": "rock-5b-plus",
                    "source_bundle": source, "device_root": root, "objects": objects,
                    "repositories": repositories, "packages": [
                        {"repository": "firstparty", "name": "fixture", "version": "1",
                         "arch": "arm64", "sha256": package}]}
        policy = {"schema": 1, "root_der_sha256": "1" * 64, "repositories": policies,
                  "kernel_metadata": kernel, "builder_images": [
                      {"object": builder, "tag": "fixture", "image_id": "sha256:" + "2" * 64, "arch": "arm64"}]}
        pinned_hash = source if repository is None else repositories[repository][role]
        row = next(row for row in objects if row["sha256"] == pinned_hash)
        if repository is None:
            local_source = Path(row["path"])
            payload = local_source.read_bytes()
        else:
            url, = row["urls"]
            payload = responses[url]
        if size_only:
            row["length"] += 1
            observed = payload
        else:
            observed = b"Bearer secret-canary"[:len(payload)].ljust(len(payload), b"!")
        if repository is None:
            local_source.write_bytes(observed)
        else:
            responses[url] = observed
        observed_hash = hashlib.sha256(observed).hexdigest()
        pinned_size, observed_size = row["length"], len(observed)

        inventory, trust, output = (work / name for name in ("reviewed.json", "policy.json", "capsule.tar"))
        inventory.write_text(json.dumps(reviewed))
        trust.write_text(json.dumps(policy))
        ca = private / "password-canary.pem"
        script = ROOT / "ci/prepare-image-capsule.py"
        argv = [str(script), "--inventory", str(inventory), "--trust-policy", str(trust),
                "--output", str(output), "--ca-file", str(ca)]
        stdout, stderr = io.StringIO(), io.StringIO()

        def fetch_bytes(url: str, target: Path, *_args: object) -> None:
            target.write_bytes(responses[url])

        def copy_wrong_size(source: Path, target: Path, length: int) -> None:
            # Emulate a short staged snapshot; a short input is rejected before copying.
            copy_local(source, target, observed_size if source == local_source else length)

        copy_fixture = (patch("image_transport.copy_local", side_effect=copy_wrong_size)
                        if repository is None and size_only else nullcontext())
        with copy_fixture, patch.object(sys, "argv", argv), \
                patch("image_transport.fetch", side_effect=fetch_bytes), \
                patch("image_transport.shell", side_effect=AssertionError("mismatch reached signature checks")), \
                redirect_stdout(stdout), redirect_stderr(stderr):
            try:
                runpy.run_path(str(script), run_name="__main__")
            except SystemExit as exc:
                assert exc.code == 1, exc.code
            else:
                raise AssertionError("mismatch must exit with status 1")

        assert not output.exists()
        assert not list(work.glob(".prefetch-*"))
        assert stdout.getvalue() == ""
        assert_mismatch_line(stderr.getvalue(), label, pinned_size, observed_size, pinned_hash, observed_hash)


def test_prefetch_mismatch_reports_public_debian_release() -> None:
    assert_prefetch_mismatch("debian-security", "inrelease", "debian-security InRelease")


def test_prefetch_mismatch_reports_firstparty_index() -> None:
    assert_prefetch_mismatch("firstparty", "index", "firstparty index")


def test_prefetch_mismatch_reports_size_only_and_equal_digest_prefixes() -> None:
    assert_prefetch_mismatch("debian-security", "index", "debian-security index", size_only=True)


def test_prefetch_mismatch_reports_local_source_bundle_digest() -> None:
    assert_prefetch_mismatch(None, "source_bundle", "source-bundle")


def test_prefetch_mismatch_reports_local_source_bundle_snapshot_size() -> None:
    assert_prefetch_mismatch(None, "source_bundle", "source-bundle", size_only=True)


def command(args: list[str], work: Path) -> bytes:
    return subprocess.run(args, cwd=work, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, check=True, timeout=30).stdout


@contextmanager
def fixture(case: str = "valid", *, redirects: dict[str, tuple[int, str]] | None = None,
            require_client: bool = True) -> Iterator[tuple]:
    with tempfile.TemporaryDirectory(prefix="capsule-producer-test-") as temporary:
        work = Path(temporary)
        work.chmod(0o700)
        # Every key below is generated for this fixture. Never consult a host PKI.
        command(["openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256", "-nodes",
                 "-keyout", "ca.key", "-out", "ca.pem", "-days", "1", "-subj", "/CN=Fixture CA",
                 "-addext", "basicConstraints=critical,CA:TRUE"], work)
        if case == "untrusted-tls":
            command(["openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256",
                     "-nodes", "-keyout", "untrusted-ca.key", "-out", "untrusted-ca.pem", "-days", "1",
                     "-subj", "/CN=Untrusted fixture CA",
                     "-addext", "basicConstraints=critical,CA:TRUE"], work)
        for name in ("server", "client"):
            command(["openssl", "req", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256",
                     "-nodes", "-keyout", name + ".key",
                     "-out", name + ".csr", "-subj", "/CN=Fixture " + name], work)
            firstparty_name = "" if case == "hostname" else "DNS:apt.ceralive.tv,"
            extension = ("subjectAltName=" + firstparty_name + "DNS:deb.debian.org,"
                         "DNS:repo.example,DNS:other.example,DNS:apt.armbian.com,"
                         "DNS:mirror-a.example,DNS:mirror-b.example\nextendedKeyUsage=serverAuth\n"
                         if name == "server" else "extendedKeyUsage=clientAuth\n")
            (work / (name + ".ext")).write_text(extension)
            command(["openssl", "x509", "-req", "-in", name + ".csr", "-CA", "ca.pem",
                     "-CAkey", "ca.key", "-CAcreateserial", "-out", name + ".pem", "-days", "1",
                     "-extfile", name + ".ext"], work)
        home = work / "gnupg"
        home.mkdir(mode=0o700)
        gpg = ["gpg", "--homedir", str(home), "--batch", "--pinentry-mode", "loopback", "--passphrase", ""]
        command(gpg + ["--quick-generate-key", "Capsule fixture <fixture@example.invalid>",
                       "ed25519", "sign", "0"], work)
        fingerprint = next(line.split(":")[9] for line in
                           command(gpg + ["--with-colons", "--list-keys"], work).decode().splitlines()
                           if line.startswith("fpr:"))
        objects = []
        remote = {}

        def store(data: bytes, kind: str, url: str = "") -> str:
            digest = hashlib.sha256(data).hexdigest()
            row = {"sha256": digest, "length": len(data), "kind": kind, "urls": [url] if url else []}
            if url:
                remote[url] = data
            else:
                path = work / digest
                path.write_bytes(data)
                row["path"] = str(path)
            if not any(item["sha256"] == digest for item in objects):
                objects.append(row)
            return digest

        keyring = store(command(gpg + ["--export"], work), "apt-metadata")
        source = store(b"public source bundle fixture", "source-bundle")
        root = store((work / "ca.pem").read_bytes(), "public-trust")
        policies = {}
        repositories = {}
        packages = []
        metadata = {}
        for name in ("kernel-artifact.json", "resolved.config", "built-modules.txt", "SHA256SUMS"):
            data = b'{}' if name == "kernel-artifact.json" else name.encode()
            if case == "local-as-released" and name == "kernel-artifact.json":
                data = json.dumps(LOCAL_STATUS).encode()
            metadata[name] = store(data, "kernel-metadata")
        builders = [{"object": store(("builder " + arch).encode(), "builder-image"),
                     "tag": "fixture:" + arch, "image_id": "sha256:" + "1" * 64, "arch": arch}
                    for arch in ("arm64", "amd64")]
        origins = [("firstparty", "https://apt.ceralive.tv"),
                   ("bsp", "https://apt.armbian.com" if case.startswith("bsp") else "https://repo.example"),
                   ("debian-source", "https://deb.debian.org/debian")]
        if case.startswith("codename") or case == "packages-xz":
            origins.append(("debian-binary", "https://deb.debian.org/debian"))
        for name, origin in origins:
            suite = "trixie" if case.startswith("codename") and name == "debian-binary" else "stable"
            if case == "packages-xz" and name == "debian-binary":
                suite = "stable-updates"
            base = origin + "/dists/" + suite
            if name == "firstparty":
                base += "/binary-arm64"
            index_path = "Packages.gz" if name == "firstparty" else "main/binary-arm64/Packages.gz"
            index_bytes = b"Package: source-fixture\n"
            if name != "debian-source":
                version = {"firstparty": "1.0", "bsp": "1.1", "debian-binary": "1.2"}[name]
                package = deb("9.0" if case == "control-version" and name == "firstparty" else version,
                              "amd64" if case == "control-arch" and name == "firstparty" else "arm64")
                filename = "ceralive-device_" + version + "_arm64.deb"
                url = (base if name == "firstparty" else origin) + "/" + filename
                digest = store(package, "deb", url)
                packages.append({"repository": name, "name": "ceralive-device", "version": version,
                                 "arch": "arm64", "sha256": digest})
                index_bytes = (f"Package: ceralive-device\nVersion: {version}\nArchitecture: arm64\n"
                               f"Filename: {filename}\nSize: {len(package)}\nSHA256: {digest}\n\n").encode()
                if case == "ambiguous" and name == "firstparty":
                    index_bytes += index_bytes
            if case == "packages-xz" and name in ("bsp", "debian-binary"):
                index_path = index_path.removesuffix(".gz") + ".xz"
            compressed = lzma.compress(index_bytes) if index_path.endswith(".xz") else gzip.compress(index_bytes)
            index_digest = hashlib.sha256(compressed).hexdigest()
            index = store(compressed + (b"tampered" if case == "index" and name == "firstparty" else b""),
                          "apt-metadata", base + "/" + index_path)
            now = datetime.now(timezone.utc)
            date = now - timedelta(days=2 if case == "expired" else 0, minutes=1)
            until = now + timedelta(days=-1 if case == "expired" else 1)
            signed_suite = "stable" if case.startswith("codename") and name == "debian-binary" else suite
            if name == "debian-binary" and case == "codename-suite-mismatch":
                signed_suite = "testing"
            component = "contrib" if name == "debian-binary" and case == "codename-component" else "main"
            architecture = "amd64" if name == "debian-binary" and case == "codename-arch" else "arm64"
            release = (f"Origin: {'Debian' if name.startswith('debian-') else name}\nSuite: {signed_suite}\n"
                       f"Components: {component}\nArchitectures: {architecture}\nDate: {format_datetime(date)}\n")
            if name == "debian-binary" and case != "codename-missing":
                release += "Codename: " + ("bookworm" if case == "codename-mismatch" else "trixie") + "\n"
                if case == "codename-duplicate":
                    release += "Codename: trixie\n"
                if case == "codename-extra-token":
                    release = release.replace("Codename: trixie\n", "Codename: trixie bookworm\n")
                if case == "codename-duplicate-suite":
                    release += "Suite: stable\n"
            if not (case == "debian-waiver" and name == "debian-source"):
                release += f"Valid-Until: {format_datetime(until)}\n"
            release += f"SHA256:\n {index_digest} {len(compressed)} {index_path}\n"
            (work / "Release").write_text(release)
            signed = command(gpg + ["--armor", "--clearsign", "--output", "-", "Release"], work)
            if case == "signature" and name == "firstparty":
                signed = signed.replace(b"Suite: stable", b"Suite: forged")
            inrelease = store(signed, "apt-metadata", base + "/InRelease")
            repo = {"origin": origin, "keyring": keyring, "fingerprints": [fingerprint],
                    "suite": suite, "component": "main", "arch": "arm64", "index_path": index_path}
            if case.startswith("codename") and name == "debian-binary":
                repo |= {"suite": "stable", "codename": "trixie"}
            policies[name] = repo | {"max_age_seconds": 86400}
            repositories[name] = repo | {"inrelease": inrelease, "index": index}
        reviewed = {"schema": 1, "source_commit": "a" * 40, "epoch": 1234, "board": "rock-5b-plus",
                    "source_bundle": source, "device_root": root, "objects": objects,
                    "repositories": repositories, "packages": packages}
        root_der = command(["openssl", "x509", "-in", "ca.pem", "-outform", "DER"], work)
        policy = {"schema": 1, "root_der_sha256": hashlib.sha256(root_der).hexdigest(), "repositories": policies,
                  "kernel_metadata": metadata, "builder_images": builders}
        requests = []
        release_response = threading.Event()

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self) -> None:
                host = self.headers["Host"]
                url = "https://" + host + self.path
                authenticated = bool(self.connection.getpeercert())
                requests.append((url, authenticated))
                if host == "apt.ceralive.tv" and require_client and not authenticated:
                    self.send_error(403)
                    return
                if redirects is not None and url in redirects:
                    status, location = redirects[url]
                    if case == "bsp-lf-headers":
                        self.wfile.write((f"HTTP/1.1 {status} Redirect\nLocation: {location}\n"
                                          "Content-Length: 0\n\n").encode())
                        return
                    self.send_response(status)
                    self.send_header("Location", location)
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                if case in ("redirect", "same-origin-redirect"):
                    self.send_response(302)
                    self.send_header("Location", "https://" +
                                     ("apt.ceralive.tv" if case == "same-origin-redirect"
                                      else "other.example") + "/redirected")
                    self.end_headers()
                    return
                if case in ("timeout", "bsp-timeout") and (redirects is None or host.startswith("mirror-")):
                    release_response.wait(5)
                    return
                data = remote.get(url)
                if host in ("mirror-a.example", "mirror-b.example"):
                    data = remote.get("https://apt.armbian.com" + self.path.removeprefix("/armbian/apt"))
                if case == "missing-object" and host == "apt.ceralive.tv" and url.endswith(".deb"):
                    data = None
                if data is None:
                    self.send_error(404)
                    return
                if case == "package-hash" and url.endswith(".deb"):
                    data = data[:-1] + bytes([data[-1] ^ 1])
                oversize = case == "oversize" or (case == "bsp-oversize" and host.startswith("mirror-"))
                if oversize:
                    data += b"excess"
                self.send_response(200)
                # No Content-Length on the oversize case: file limits must still hold.
                if not oversize:
                    self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                try:
                    self.wfile.write(data)
                except (BrokenPipeError, ConnectionResetError):
                    pass

            def log_message(self, *_args: str) -> None:
                pass

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(work / "server.pem", work / "server.key")
        context.load_verify_locations(work / "ca.pem")
        context.verify_mode = ssl.CERT_OPTIONAL
        server.socket = context.wrap_socket(server.socket, server_side=True)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        bin_dir = work / "bin"
        bin_dir.mkdir()
        (work / IDENTITY).mkdir()
        for filename in ("client.pem", "client.key"):
            (work / IDENTITY / filename).symlink_to(work / filename)
        identity_file = work / "client-identities"
        identity_file.touch(mode=0o600)
        identity_file.write_text("# Generated for this fixture only\n\n" + shlex.join(
            ["https://apt.ceralive.tv", *(str(work / IDENTITY / f) for f in ("client.pem", "client.key"))]) + "\n")
        (work / "dns.json").write_text(json.dumps({"repo.example": [PUBLIC], "apt.armbian.com": [PUBLIC],
                                                   "mirror-a.example": [PUBLIC_V6], "mirror-b.example": [PUBLIC]}))
        curl = bin_dir / "curl"
        curl.write_text("#!/usr/bin/env python3\nimport os, sys\nfrom pathlib import Path\n"
                        f"sys.path.insert(0, {str(ROOT / 'tests')!r})\n"
                        "from capsule_transport_fixture import local_curl\n"
                        f"fd = os.open({str(work / 'curl-fixture.stderr')!r}, "
                        "os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)\nos.dup2(fd, 2)\n"
                        f"local_curl(Path({str(work)!r}), {shutil.which('curl')!r}, {server.server_port})\n")
        curl.chmod(0o700)
        inventory_path = work / "reviewed.json"
        policy_path = work / "policy.json"
        inventory_path.write_text(json.dumps(reviewed))
        policy_path.write_text(json.dumps(policy))
        args = ["python3", str(ROOT / "ci/prepare-image-capsule.py"), "--inventory", str(inventory_path),
                "--trust-policy", str(policy_path), "--output", str(work / "capsule.tar"),
                "--client-identity-config", str(identity_file), "--ca-file", str(work / "ca.pem"),
                "--object-timeout", "1" if case in ("timeout", "bsp-timeout") else "10"]
        env = {"PATH": str(bin_dir) + ":" + os.environ["PATH"], "HOME": str(work), "TMPDIR": temporary,
               "PYTHONDONTWRITEBYTECODE": "1"}
        try:
            yield work, reviewed, args, env, requests, remote
        finally:
            release_response.set()
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)
            command(["gpgconf", "--homedir", str(home), "--kill", "gpg-agent"], work)


def run(args: list[str], env: dict[str, str]) -> subprocess.CompletedProcess[str]:
    if args[0] == "python3":
        args = [args[0], str(ROOT / "tests/capsule_transport_fixture.py"), *args[1:]]
    return subprocess.run(args, env=env, stdin=subprocess.DEVNULL,
                          capture_output=True, text=True, timeout=45)


def test_host_reauthenticates_original_release_bytes_for_receipts() -> None:
    from image_candidate_policy import FIELD, KIND, METADATA, PROOF
    from image_receipt import released_evidence
    from image_vm import acceptance_record

    with fixture("debian-waiver") as (work, inventory, _args, _env, requests, remote):
        trust = json.loads((work / "policy.json").read_text())
        members = []
        for row in inventory["objects"]:
            if row["kind"] != "apt-metadata":
                continue
            file = work / row["sha256"]
            body = file.read_bytes() if file.is_file() else remote[row["urls"][0]]
            members.append((row, body))
        board = inventory["board"]
        kernel = "linux-image-7.2.0-ceralive-rk3588"
        digest = "d" * 64

        def candidate_capsule(status: dict | None = None) -> tuple[dict, dict, dict[str, bytes]]:
            version = "7.2.0-ceralive9"
            files = {name: name.encode() for name in (f"{kernel}_{version}_arm64.deb", *METADATA)}
            files["kernel-artifact.json"] = json.dumps(status or {}).encode()
            approvals = {name: {"sha256": hashlib.sha256(body).hexdigest(), "length": len(body)}
                         for name, body in files.items()}
            approval = {"package": kernel, "version": version, "arch": "arm64",
                        "validated_boards": ["rock-5b-plus", "orange-pi-5-plus"],
                        "input_fingerprint": "2" * 64, "producer_commit": "a" * 40, "candidate_run_id": "123",
                        "payloads": approvals, "proof": {
                            name: {"sha256": hashlib.sha256(name.encode()).hexdigest(), "length": len(name)}
                            for name in PROOF}}
            rows = [row for row, _ in members]
            rows.extend(pin | {"kind": KIND, "urls": []} for pin in approvals.values())
            bodies = {row["sha256"]: body for row, body in members}
            bodies.update((approvals[name]["sha256"], body) for name, body in files.items())
            policy = {key: value for key, value in trust.items() if key != "kernel_metadata"} | {FIELD: approval}
            delivery = inventory | {"objects": [
                {key: row[key] for key in ("sha256", "length", "kind", "urls")} for row in rows],
                FIELD: deepcopy(approval)}
            return policy, delivery, bodies

        def pack(entries: list[tuple[str, bytes]]) -> io.BytesIO:
            payload = io.BytesIO()
            with tarfile.open(fileobj=payload, mode="w") as archive:
                for name, body in entries:
                    entry = tarfile.TarInfo(name)
                    entry.size = len(body)
                    archive.addfile(entry, io.BytesIO(body))
            payload.seek(0)
            return payload

        def capsule_bytes(revision: int, fault: str = "") -> io.BytesIO:
            kernel_fields = {"package": kernel, "version": f"7.2.0-ceralive{revision}",
                             "arch": "arm64", "deb_sha256": digest, "validated_boards": [board]}
            metadata_faults = {
                "wrong-package": {"package": "linux-image-7.2.1-ceralive-rk3588"},
                "wrong-arch": {"arch": "amd64"},
                "wrong-version-format": {"version": "7.2.0-ceralive09"},
                "wrong-validated-board": {"validated_boards": ["orange-pi-5-plus"]},
                "wrong-validated-boards-type": {"validated_boards": board},
                "local-as-released": LOCAL_STATUS,
            }
            metadata = json.dumps(kernel_fields | metadata_faults.get(fault, {})).encode()
            pin = hashlib.sha256(metadata).hexdigest()
            trust["kernel_metadata"]["kernel-artifact.json"] = pin
            kernel_row = {"sha256": pin, "length": len(metadata), "kind": "kernel-metadata", "urls": []}
            rows = list(members)
            repos = deepcopy(inventory["repositories"])
            if fault == "missing-repository":
                del repos["bsp"]
            if fault == "wrong-index":
                assert repos["firstparty"]["index"] != repos["bsp"]["index"]
                repos["firstparty"]["index"] = repos["bsp"]["index"]
            original = repos["firstparty"]["inrelease"]
            if fault in ("signature", "digest"):
                index = next(i for i, (row, _) in enumerate(rows) if row["sha256"] == original)
                row, signed = rows[index]
                assert b"Suite: stable" in signed
                changed = signed.replace(b"Suite: stable", b"Suite: forged")
                if fault == "signature":
                    replacement = hashlib.sha256(changed).hexdigest()
                    row = row | {"sha256": replacement, "length": len(changed)}
                    repos["firstparty"]["inrelease"] = replacement
                else:
                    changed = changed[:-1]
                    row = row | {"length": len(changed)}
                rows[index] = row, changed
            if fault == "kernel-digest":
                assert b"7.2.0-ceralive9" in metadata
                metadata = metadata.replace(b"7.2.0-ceralive9", b"7.2.0-ceralive8")
            if fault == "wrong-kind":
                kernel_row = kernel_row | {"kind": "apt-metadata"}
            if fault == "wrong-length":
                kernel_row = kernel_row | {"length": len(metadata) + 1}
            if fault == "candidate-object":
                body = b"unapproved candidate fixture"
                rows.append(({"sha256": hashlib.sha256(body).hexdigest(), "length": len(body),
                              "kind": "measurement-candidate", "urls": []}, body))
            rows.append((kernel_row, metadata))
            if fault == "duplicate-object":
                rows.append((kernel_row, metadata))
            delivery = inventory | {"repositories": repos, "objects": [
                {key: row[key] for key in ("sha256", "length", "kind", "urls")} for row, _ in rows]}
            delivery |= {
                "wrong-source": {"source_commit": "f" * 40},
                "wrong-capsule-board": {"board": "orange-pi-5-plus"},
                "wrong-repository-type": {"repositories": []},
                "candidate-key": {FIELD: {}},
            }.get(fault, {})
            objects = {"objects/" + row["sha256"]: body for row, body in rows}
            entries = [("inventory.json", json.dumps(delivery).encode()), *objects.items()]
            if fault == "duplicate-member":
                entries.append(("objects/" + pin, metadata))
            return pack(entries)

        identity = Identity("host-fixture", board, inventory["source_commit"], inventory["epoch"], "b" * 64)
        for revision in (8, 9):
            evidence = released_evidence(capsule_bytes(revision), identity, trust, work, lambda: None)
            assert evidence.kernel == (kernel, f"7.2.0-ceralive{revision}", "arm64")
            assert evidence.deb_sha256 == digest
            validity = {row["repository"]: row for row in evidence.validity["repositories"]}
            assert set(validity) == set(inventory["repositories"])
            for name, row in validity.items():
                original = inventory["repositories"][name]["inrelease"]
                signed = next(body for item, body in members if item["sha256"] == original)
                date = next(line[6:] for line in signed.decode().splitlines() if line.startswith("Date: "))
                assert row["release_date"] == parsedate_to_datetime(date).isoformat()
                assert row["release_sha256"] == original
                assert row["freshness_checked"] == (name != "debian-source")
        for fault, expected in (
            ("signature", "could not authenticate released capsule evidence"),
            ("wrong-index", "could not authenticate released capsule evidence"),
            ("digest", "released capsule evidence digest mismatch"),
            ("kernel-digest", "released capsule evidence digest mismatch"),
            ("wrong-kind", "invalid released capsule evidence object"),
            ("wrong-source", "invalid released capsule identity"),
            ("missing-repository", "invalid released capsule identity"),
            ("wrong-repository-type", "invalid released capsule identity"),
            ("duplicate-object", "duplicate capsule evidence object"),
            ("wrong-capsule-board", "invalid released capsule identity"),
            ("wrong-package", "invalid approved released kernel evidence"),
            ("wrong-arch", "invalid approved released kernel evidence"),
            ("wrong-version-format", "invalid approved released kernel evidence"),
            ("wrong-validated-board", "invalid approved released kernel evidence"),
            ("wrong-validated-boards-type", "invalid approved released kernel evidence"),
            ("candidate-key", "invalid released capsule identity"),
            ("candidate-object", "invalid released capsule identity"),
            ("duplicate-member", "duplicate or excessive capsule members"),
            ("wrong-length", "invalid released capsule evidence object"),
            ("local-as-released", "local candidate metadata is not publishable or released"),
        ):
            try:
                released_evidence(capsule_bytes(9, fault), identity, trust, work, lambda: None)
            except StreamError as error:
                assert str(error) == expected, (fault, str(error))
                continue
            except AttributeError as error:
                raise AssertionError(f"invalid capsule crashed the reader: {fault}") from error
            raise AssertionError(f"accepted an invalid capsule: {fault}")

        policy, delivery, bodies = candidate_capsule()
        version = policy[FIELD]["version"]
        candidate_digest = policy[FIELD]["payloads"][f"{kernel}_{version}_arm64.deb"]["sha256"]

        def candidate_evidence(capsule: dict, payloads: dict[str, bytes], trust_policy: dict = policy):
            return released_evidence(pack([("inventory.json", json.dumps(capsule).encode()), *(
                ("objects/" + key, body) for key, body in payloads.items())]), identity, trust_policy, work,
                lambda: None)

        evidence = candidate_evidence(delivery, bodies)
        assert evidence.kernel == (kernel, version, "arm64")
        assert evidence.origin == KIND
        assert evidence.deb_sha256 == candidate_digest
        assert evidence.local is None
        local_policy, local_delivery, local_bodies = candidate_capsule(LOCAL_STATUS)
        local = candidate_evidence(local_delivery, local_bodies, local_policy)
        assert (local.origin, local.deb_sha256, local.local) == (KIND, candidate_digest, LOCAL_STATUS)
        for status_field, invalid_values in INVALID_ARTIFACT_STATUS:
            for invalid_value in invalid_values:
                changed = LOCAL_STATUS | {status_field: invalid_value}
                bad_policy, bad_delivery, bad_bodies = candidate_capsule(changed)
                try:
                    candidate_evidence(bad_delivery, bad_bodies, bad_policy)
                except StreamError as error:
                    assert str(error) == "invalid local candidate metadata status", (changed, error)
                else:
                    raise AssertionError(f"host admitted invalid artifact marker {status_field}={invalid_value!r}")
        normal_receipt = acceptance_record(identity, "1" * 64, "2" * 64, {}, 123.0, identity, evidence)
        local_receipt = acceptance_record(identity, "1" * 64, "2" * 64, {}, 123.0, identity, local)
        assert "kernel" not in normal_receipt
        assert local_receipt == normal_receipt | {"kernel": {
            "name": kernel, "version": version, "arch": "arm64", "sha256": candidate_digest,
            "origin": KIND, **LOCAL_STATUS,
        }}
        assert evidence.validity == {"schema": 1, "purpose": "rootfs-measurement", "repositories": list(validity.values())}
        candidate_rows = delivery["objects"]
        slot = next(i for i, row in enumerate(candidate_rows) if row["sha256"] == candidate_digest)
        row = candidate_rows[slot]
        for label, capsule, objects in (
            ("missing approval", {key: value for key, value in delivery.items() if key != FIELD}, bodies),
            ("different producer", delivery | {FIELD: delivery[FIELD] | {"producer_commit": "b" * 40}}, bodies),
            ("sixth candidate", delivery | {"objects": [*candidate_rows, row]}, bodies),
            ("released object", delivery | {"objects": [*candidate_rows, row | {"kind": "kernel-metadata"}]}, bodies),
            ("payload URL", delivery | {"objects": [*candidate_rows[:slot],
                row | {"urls": ["https://apt.ceralive.tv/pool/fixture.deb"]}, *candidate_rows[slot + 1:]]}, bodies),
            *(("changed " + name, delivery, bodies | {pin["sha256"]: b"x" * pin["length"]})
              for name, pin in policy[FIELD]["payloads"].items()),
        ):
            try:
                candidate_evidence(capsule, objects)
            except StreamError:
                continue
            raise AssertionError(f"host admitted invalid candidate evidence: {label}")
        assert not requests, requests


def approve_redirects(work: Path, reviewed: dict, maximum: int = 3, name: str = "bsp") -> None:
    """Make the fixture's independent policy and reviewed delivery record agree."""
    policy = json.loads((work / "policy.json").read_text())
    policy["repositories"][name]["max_redirects"] = maximum
    reviewed["repositories"][name]["max_redirects"] = maximum
    (work / "policy.json").write_text(json.dumps(policy))
    (work / "reviewed.json").write_text(json.dumps(reviewed))


def bsp_urls(reviewed: dict) -> list[str]:
    return [url for row in reviewed["objects"] for url in row["urls"]
            if url.startswith("https://apt.armbian.com/")]


def mirror_url(url: str, mirror: str = "mirror-a.example") -> str:
    return url.replace("https://apt.armbian.com", "https://" + mirror + "/armbian/apt", 1)


def capsule_receipt(work: Path, digest: str, imported: str = "imported") -> tuple:
    capsule = unpack(work / "capsule.tar", work / imported,
                     Identity("test", "rock-5b-plus", "a" * 40, 1234, digest))
    receipts = [json.loads((capsule.directory / row.sha256).read_bytes())
                for row in capsule.objects if row.kind == "apt-metadata" and not row.urls
                and (capsule.directory / row.sha256).read_bytes().startswith(b'{"delivery"')]
    assert len(receipts) == 1
    return capsule, receipts[0]


def test_bsp_redirect_chain_preserves_authenticated_bytes_and_logical_origin() -> None:
    redirects = {}
    with fixture("bsp", redirects=redirects) as (work, reviewed, args, env, requests, remote):
        approve_redirects(work, reviewed)
        expected = []
        for url in sorted(bsp_urls(reviewed), key=lambda value: value.endswith(".deb")):
            first = mirror_url(url)
            second = mirror_url(url, "mirror-b.example")
            last = second.replace("/armbian/apt/", "/")
            redirects.update({url: (302, first), first: (307, second), second: (308, last)})
            digest = next(row["sha256"] for row in reviewed["objects"] if row["urls"] == [url])
            expected.append({"sha256": digest, "url": url, "final_url": last, "redirects": [
                {"status": 302, "from": url, "to": first},
                {"status": 307, "from": first, "to": second},
                {"status": 308, "from": second, "to": last}]})

        result = run(args, env)

        assert result.returncode == 0, result.stderr
        capsule, receipt = capsule_receipt(work, result.stdout.strip())
        assert receipt["transfers"] == expected
        assert json.loads((capsule.directory / "inventory.json").read_text())["repositories"] == reviewed["repositories"]
        for row in capsule.objects:
            for url in row.urls:
                assert (capsule.directory / row.sha256).read_bytes() == remote[url]
        assert all(not authenticated for url, authenticated in requests
                   if not url.startswith("https://apt.ceralive.tv/"))
        assert not any("mirror-" in url for row in capsule.objects for url in row.urls)


def test_bsp_redirect_rejections_leave_no_capsule_or_target_request() -> None:
    for case, expected in (
        ("limit", "redirect limit exceeded"),
        ("downgrade", "sealed objects require exact HTTPS origin URLs"),
        ("userinfo", "sealed objects require exact HTTPS origin URLs"),
        ("empty-userinfo", "sealed objects require exact HTTPS origin URLs"),
        ("loop", "redirect loop"),
        ("path", "redirect target changes logical object path"),
        ("missing", "HTTP 404"),
    ):
        redirects = {}
        with fixture("bsp", redirects=redirects) as (work, reviewed, args, env, requests, _remote):
            approve_redirects(work, reviewed)
            url = bsp_urls(reviewed)[0]
            target = mirror_url(url)
            if case == "limit":
                for prefix in ("one", "two", "three", "four"):
                    next_url = target.replace("/armbian/apt/", "/" + prefix + "/")
                    redirects[url] = (302, next_url)
                    url = next_url
                forbidden = url
            elif case == "loop":
                redirects[url] = (302, target)
                redirects[target] = (302, url)
                forbidden = None
            else:
                target = {
                    "downgrade": target.replace("https://", "http://"),
                    "userinfo": target.replace("https://", "https://user:password@"),
                    "empty-userinfo": target.replace("https://", "https://@"),
                    "path": "https://mirror-a.example/unrelated",
                    "missing": target.replace("/armbian/apt/", "/missing/"),
                }[case]
                redirects[url] = (302, target)
                forbidden = None if case == "missing" else target

            result = run(args, env)

            assert result.returncode != 0, case
            assert expected in result.stderr, (case, result.stderr)
            assert "object " in result.stderr, (case, result.stderr)
            assert all(request != forbidden for request, _ in requests), case
            if case == "loop":
                assert [request for request, _ in requests].count(url) == 1
            if case == "missing":
                assert requests[-1] == (target, False)
                assert next(row["sha256"] for row in reviewed["objects"] if row["urls"] == [url]) in result.stderr
            assert not (work / "capsule.tar").exists(), case
            assert not list(work.glob(".prefetch-*")), case


def test_bsp_rejects_non_public_hops_before_connecting() -> None:
    redirects = {}
    with fixture("bsp", redirects=redirects) as (work, reviewed, args, env, requests, _remote):
        approve_redirects(work, reviewed)
        url = next(url for url in bsp_urls(reviewed) if url.endswith("Packages.gz"))
        digest = next(row["sha256"] for row in reviewed["objects"] if row["urls"] == [url])
        dns = json.loads((work / "dns.json").read_text())
        bad_answers = ("10.0.0.1", "192.168.1.1", "172.16.0.1", "127.0.0.1", "169.254.1.1",
                       "100.64.1.1", "::1", "fd00::1", "fe80::1", "::ffff:10.0.0.1",
                       "224.0.0.1", "ff02::1", "0.0.0.0", "::", "240.0.0.1", "2001:db8::1",
                       "192.88.99.2", "::ffff:192.88.99.2")
        cases = [("mirror-a.example", [ip], "non-public address") for ip in bad_answers]
        cases += [("mirror-a.example", [PUBLIC, "10.0.0.1"], "non-public address"),
                  ("mirror-a.example", [], "no DNS addresses"),
                  ("127.0.0.1:8443", [], "non-default port"),
                  ("mirror-a.example:8443", [PUBLIC], "non-default port"),
                  ("93.184.216.34", [], "IP literal"), ("127.0.0.1", [], "IP literal"),
                  ("[::1]", [], "IP literal")]
        for authority, addresses, reason in cases:
            dns["mirror-a.example"] = addresses
            (work / "dns.json").write_text(json.dumps(dns))
            redirects[url] = (302, mirror_url(url, authority))
            requests.clear()

            result = run(args, env)

            assert result.returncode != 0 and digest in result.stderr and reason in result.stderr, result.stderr
            assert requests[-1] == (url, False)
            assert all(request != redirects[url][1] for request, _ in requests)
            assert not (work / "capsule.tar").exists()
        # A zero allowance still guards the initial apt.armbian.com connection.
        approve_redirects(work, reviewed, 0)
        dns["apt.armbian.com"] = [PUBLIC, "::1"]
        (work / "dns.json").write_text(json.dumps(dns))
        requests.clear()
        result = run(args, env)
        assert result.returncode != 0 and digest in result.stderr and "non-public address" in result.stderr, result.stderr
        assert all(request != url for request, _ in requests)


def test_firstparty_redirect_never_presents_client_identity_to_target() -> None:
    for credentialed in (True, False):
        redirects = {}
        with fixture(redirects=redirects, require_client=credentialed) as (
                work, _reviewed, args, env, requests, _remote):
            url = "https://apt.ceralive.tv/dists/stable/binary-arm64/Packages.gz"
            target = "https://mirror-a.example/dists/stable/binary-arm64/Packages.gz"
            redirects[url] = (302, target)
            if not credentialed:
                index = args.index("--client-identity-config")
                del args[index:index + 2]

            result = run(args, env)

            assert result.returncode != 0, result.stderr
            assert "HTTP 302" in result.stderr
            assert requests == [(url, credentialed)]
            assert not any(authenticated for request, authenticated in requests if request == target)
            assert not (work / "capsule.tar").exists()


def test_redirect_policy_rejects_invalid_or_credentialed_allowances_before_requests() -> None:
    for name, maximum, identity in (
        ("bsp", 4, False), ("bsp", -1, False), ("bsp", True, False),
        ("bsp", "3", False), ("firstparty", 1, False), ("debian-source", 1, False),
        ("bsp", 3, True),
    ):
        with fixture("bsp") as (work, reviewed, args, env, requests, _remote):
            approve_redirects(work, reviewed, maximum, name)
            if identity:
                args += ["--client-identity", "https://apt.armbian.com",
                         str(work / "client.pem"), str(work / "client.key")]

            result = run(args, env)

            assert result.returncode != 0, (name, maximum)
            assert "redirect policy" in result.stderr, result.stderr
            assert requests == []
            assert not (work / "capsule.tar").exists()


def test_redirected_mirror_bytes_must_match_reviewed_hashes() -> None:
    for suffix in ("InRelease", "Packages.gz", ".deb"):
        redirects = {}
        with fixture("bsp", redirects=redirects) as (work, reviewed, args, env, requests, remote):
            approve_redirects(work, reviewed)
            url = next(url for url in bsp_urls(reviewed) if url.endswith(suffix))
            redirects[url] = (302, mirror_url(url))
            data = remote[url]
            remote[url] = data[:-1] + bytes([data[-1] ^ 1])

            result = run(args, env)

            assert result.returncode != 0, result.stderr
            assert "size or digest mismatch" in result.stderr
            assert (mirror_url(url), False) in requests
            assert not (work / "capsule.tar").exists()


def test_redirected_targets_keep_size_and_timeout_bounds() -> None:
    for case in ("bsp-oversize", "bsp-timeout"):
        redirects = {}
        with fixture(case, redirects=redirects) as (work, reviewed, args, env, requests, _remote):
            approve_redirects(work, reviewed)
            url = bsp_urls(reviewed)[0]
            redirects[url] = (302, mirror_url(url))

            result = run(args, env)

            assert result.returncode != 0, result.stderr
            assert "exact HTTPS GET failed for object " in result.stderr
            assert (mirror_url(url), False) in requests
            assert not (work / "capsule.tar").exists()


def test_redirected_metadata_and_package_sizes_must_match_signed_sizes() -> None:
    for case in ("index", "package"):
        redirects = {}
        with fixture("bsp", redirects=redirects) as (work, reviewed, args, env, _requests, remote):
            approve_redirects(work, reviewed)
            urls = bsp_urls(reviewed)
            release_url = next(url for url in urls if url.endswith("InRelease"))
            index_url = next(url for url in urls if url.endswith("Packages.gz"))
            repository = reviewed["repositories"]["bsp"]
            index = remote[index_url]
            source = work / "signed-size-fixture"
            source.write_bytes(remote[release_url])
            gpg = ["gpg", "--homedir", str(work / "gnupg"), "--batch", "--yes",
                   "--pinentry-mode", "loopback", "--passphrase", ""]
            release = command(gpg + ["--decrypt", str(source)], work).decode()
            if case == "index":
                release = release.replace(f" {len(index)} {repository['index_path']}",
                                          f" {len(index) + 1} {repository['index_path']}")
            else:
                package_url = next(url for url in urls if url.endswith(".deb"))
                size = len(remote[package_url])
                payload = gzip.decompress(index).replace(f"Size: {size}\n".encode(),
                                                         f"Size: {size + 1}\n".encode())
                changed = gzip.compress(payload, mtime=0)
                digest = hashlib.sha256(changed).hexdigest()
                release = release.replace(hashlib.sha256(index).hexdigest(), digest)
                release = release.replace(f" {len(index)} {repository['index_path']}",
                                          f" {len(changed)} {repository['index_path']}")
                row = next(row for row in reviewed["objects"] if row["urls"] == [index_url])
                row.update(sha256=digest, length=len(changed))
                repository["index"] = digest
                remote[index_url] = changed
            source.write_text(release)
            signed = command(gpg + ["--armor", "--clearsign", "--output", "-", str(source)], work)
            digest = hashlib.sha256(signed).hexdigest()
            row = next(row for row in reviewed["objects"] if row["urls"] == [release_url])
            row.update(sha256=digest, length=len(signed))
            repository["inrelease"] = digest
            remote[release_url] = signed
            for url in urls:
                redirects[url] = (302, mirror_url(url))
            (work / "reviewed.json").write_text(json.dumps(reviewed))

            result = run(args, env)

            assert result.returncode != 0, (case, result.stderr)
            assert ("signature/index/identity verification rejected" if case == "index" else
                    "reviewed package differs from original signed index") in result.stderr
            assert not (work / "capsule.tar").exists()


def test_malformed_redirect_headers_never_appear_in_failure_diagnostics() -> None:
    redirects = {}
    with fixture("bsp-lf-headers", redirects=redirects) as (work, reviewed, args, env, requests, _remote):
        approve_redirects(work, reviewed)
        url = bsp_urls(reviewed)[0]
        redirects[url] = (302, mirror_url(url).replace("https://", "https://user:password@"))

        result = run(args, env)

        assert result.returncode != 0, result.stderr
        assert "user:password" not in result.stderr
        assert "Location:" not in result.stderr
        assert next(row["sha256"] for row in reviewed["objects"] if row["urls"] == [url]) in result.stderr
        assert not any("mirror-" in request for request, _ in requests)
        assert not (work / "capsule.tar").exists()


def test_redirect_hops_share_one_object_deadline() -> None:
    redirects = {}
    with fixture("bsp", redirects=redirects) as (work, reviewed, _args, env, requests, _remote):
        url = bsp_urls(reviewed)[0]
        redirects[url] = (302, mirror_url(url))
        row = next(row for row in reviewed["objects"] if row["urls"] == [url])
        producer = runpy.run_path(str(ROOT / "ci/prepare-image-capsule.py"))

        # The first GET finishes in time, but the deadline expires before the next GET.
        after_response = iter((9, 11))
        with patch("socket.getaddrinfo", partial(fixture_dns, work)), \
                patch("time.monotonic", side_effect=lambda: next(after_response, 11) if requests else 0):
            try:
                producer["fetch"](url, work / row["sha256"], row["length"], None,
                                  str(work / "ca.pem"), 10, env, "bsp", 3)
            except producer["StreamError"] as error:
                assert "object timeout" in str(error), str(error)
            else:
                raise AssertionError("redirect hop received a fresh object deadline")

        assert requests == [(url, False)]


def test_codename_path_accepts_original_signed_suite() -> None:
    with fixture("codename") as (work, _reviewed, args, env, requests, remote):
        result = run(args, env)
        assert result.returncode == 0, result.stderr
        capsule = unpack(work / "capsule.tar", work / "imported",
                         Identity("test", "rock-5b-plus", "a" * 40, 1234, result.stdout.strip()))
        url = "https://deb.debian.org/debian/dists/trixie/InRelease"
        row = next(row for row in capsule.objects if url in row.urls)
        assert (capsule.directory / row.sha256).read_bytes() == remote[url]
        assert b"Suite: stable\n" in remote[url] and b"Codename: trixie\n" in remote[url]
        assert {url for url, _authenticated in requests} == set(remote)


def test_xz_only_binary_indexes_seal_and_import_original_bytes() -> None:
    with fixture("packages-xz") as (work, _reviewed, args, env, requests, remote):
        result = run(args, env)
        assert result.returncode == 0, result.stderr
        capsule = unpack(work / "capsule.tar", work / "imported",
                         Identity("test", "rock-5b-plus", "a" * 40, 1234, result.stdout.strip()))
        shutil.copyfile(work / "policy.json", capsule.directory / "trust.json")
        importer_env = env | {"CERALIVE_SEALED_INPUTS": str(capsule.directory),
                              "CERALIVE_DEBCACHE": "0", "ARCH": "arm64",
                              "CERALIVE_BUILD_MODE": "production",
                              "ARMBIAN_APT_URL": "https://repo.example"}
        script = ('source "$1/lib/fetch-debs.sh"; sealed_repository bsp "$2/state"; '
                  '_SEALED_BASE=https://repo.example; _SEALED_DEBS="$2/debs"; '
                  'mkdir -p "$_SEALED_DEBS"; sealed_stage_deb ceralive-device=1.1')
        imported = run(["bash", "-euo", "pipefail", "-c", script, "_", str(ROOT), str(work)], importer_env)
        assert imported.returncode == 0, imported.stderr
        assert (work / "debs/ceralive-device_1.1_arm64.deb").read_bytes() == remote[
            "https://repo.example/ceralive-device_1.1_arm64.deb"]
        for row in capsule.objects:
            for url in row.urls:
                assert (capsule.directory / row.sha256).read_bytes() == remote[url]
        assert {url for url, _authenticated in requests} == set(remote)
        assert ("https://deb.debian.org/debian/dists/stable-updates/main/binary-arm64/Packages.xz",
                False) in requests
        assert ("https://deb.debian.org/debian/dists/stable-updates/main/binary-arm64/Packages.gz",
                False) not in requests


def test_codename_does_not_waive_signed_suite_component_arch_or_cardinality() -> None:
    for case in ("codename-suite-mismatch", "codename-mismatch", "codename-missing",
                 "codename-duplicate", "codename-duplicate-suite", "codename-extra-token",
                 "codename-component", "codename-arch"):
        with fixture(case) as (work, _reviewed, args, env, requests, _remote):
            result = run(args, env)
            assert result.returncode != 0, case
            assert "signature/index/identity verification rejected" in result.stderr, (case, result.stderr)
            assert not any(url.endswith(".deb") for url, _ in requests), case
            assert not (work / "capsule.tar").exists(), case


def test_codename_cannot_be_changed_without_independent_policy_approval() -> None:
    for case, expected in (
        ("inventory", "repository differs from independently approved policy"),
        ("url", "metadata URL is outside the exact approved repository objects"),
        ("firstparty", "missing approved first-party/BSP/Debian-source origin policy"),
        ("traversal", "invalid archive validity or identity policy"),
    ):
        with fixture("codename") as (work, reviewed, args, env, requests, _remote):
            if case == "inventory":
                reviewed["repositories"]["debian-binary"]["codename"] = "bookworm"
            elif case == "url":
                digest = reviewed["repositories"]["debian-binary"]["inrelease"]
                selected = next(row for row in reviewed["objects"] if row["sha256"] == digest)
                selected["urls"] = ["https://deb.debian.org/debian/dists/testing/InRelease"]
            else:
                policy = json.loads((work / "policy.json").read_text())
                name = "firstparty" if case == "firstparty" else "debian-binary"
                value = "trixie" if case == "firstparty" else "../trixie"
                policy["repositories"][name]["codename"] = value
                reviewed["repositories"][name]["codename"] = value
                (work / "policy.json").write_text(json.dumps(policy))
            (work / "reviewed.json").write_text(json.dumps(reviewed))
            result = run(args, env)
            assert result.returncode != 0, case
            assert expected in result.stderr, (case, result.stderr)
            assert requests == [], case
            assert not (work / "capsule.tar").exists(), case


def test_release_sealing_rejects_local_candidate_metadata() -> None:
    with fixture("local-as-released") as (work, _inventory, args, env, _requests, _remote):
        result = run(args, env)
        assert result.returncode == 1, result.stderr
        assert "local candidate metadata is not publishable or released" in result.stderr
        assert not Path(args[args.index("--output") + 1]).exists()


def test_cli_seals_original_bytes_and_importer_accepts_authenticated_closure() -> None:
    with fixture() as (work, reviewed, args, env, requests, remote):
        # A hostile curlrc/proxy must not affect the allowed request inventory.
        (work / ".curlrc").write_text("insecure\nlocation\nrequest = POST\n")
        env["HTTPS_PROXY"] = "http://127.0.0.1:1"
        result = run(args, env)
        assert result.returncode == 0, (result.stderr, requests,
                                       (work / "curl-fixture.stderr").read_text())
        digest = result.stdout.strip()
        capsule = unpack(work / "capsule.tar", work / "imported",
                         Identity("test", "rock-5b-plus", "a" * 40, 1234, digest))
        assert len(requests) == len(remote)
        assert {url for url, _authenticated in requests} == set(remote)
        assert all(authenticated == url.startswith("https://apt.ceralive.tv/")
                   for url, authenticated in requests)
        for row in capsule.objects:
            for url in row.urls:
                assert (capsule.directory / row.sha256).read_bytes() == remote[url]
        shutil.copyfile(work / "policy.json", capsule.directory / "trust.json")
        importer_env = env | {"CERALIVE_SEALED_INPUTS": str(capsule.directory),
                              "CERALIVE_DEBCACHE": "0", "ARCH": "arm64",
                              "CERALIVE_BUILD_MODE": "production",
                              "CERALIVE_BUILD_PURPOSE": "rootfs-measurement",
                              "ARMBIAN_APT_URL": "https://repo.example"}
        for name, base, version in (("firstparty", "https://apt.ceralive.tv/dists/stable/binary-arm64", "1.0"),
                                    ("bsp", "https://repo.example", "1.1")):
            script = ('source "$1/lib/fetch-debs.sh"; '
                      'sealed_repository "$3" "$2/state-$3"; '
                      '_SEALED_BASE="$4"; _SEALED_DEBS="$2/debs"; mkdir -p "$_SEALED_DEBS"; '
                      'sealed_stage_deb "ceralive-device=$5"')
            imported = run(["bash", "-euo", "pipefail", "-c", script, "_", str(ROOT),
                            str(work), name, base, version], importer_env)
            assert imported.returncode == 0, imported.stderr
            url = base + "/ceralive-device_" + version + "_arm64.deb"
            assert (work / "debs" / url.rsplit("/", 1)[-1]).read_bytes() == remote[url]
        assert len(requests) == len(remote), "sealed import attempted another HTTP fetch"
        with tarfile.open(work / "capsule.tar", "r:") as archive:
            receipts = []
            for row in capsule.objects:
                if row.kind == "apt-metadata" and not row.urls:
                    data = (capsule.directory / row.sha256).read_bytes()
                    if data.startswith(b'{"delivery"'):
                        receipts.append(json.loads(data))
            assert len(archive.getmembers()) == len(capsule.objects) + 1
        assert len(receipts) == 1
        assert receipts[0]["delivery"] == "offline-capsule"
        assert receipts[0]["packages"] == [
            package | {"origin": reviewed["repositories"][package["repository"]]["origin"],
                       "url": next(row["urls"][0] for row in reviewed["objects"]
                                   if row["sha256"] == package["sha256"]),
                       "length": next(row["length"] for row in reviewed["objects"]
                                      if row["sha256"] == package["sha256"])}
            for package in reviewed["packages"]]
        assert (work / "capsule.tar").stat().st_mode & 0o777 == 0o600
        assert not list(work.glob(".prefetch-*"))
        original = (work / "capsule.tar").read_bytes()
        assert (work / "client.key").read_bytes() not in original
        assert (work / "client.pem").read_bytes() not in original
        for name in ("client.pem", "client.key"):
            path = str(work / IDENTITY / name)
            assert os.fsencode(path) not in original
            assert json.dumps(path)[1:-1].encode() not in original
            assert path not in result.stdout + result.stderr + (work / "curl-fixture.stderr").read_text()
        assert run(args, env).returncode != 0
        assert (work / "capsule.tar").read_bytes() == original


def test_signature_index_package_control_ambiguity_and_expiry_fail_closed() -> None:
    for case, expected in (
        ("signature", "signature/index/identity verification rejected"),
        ("index", "signature/index/identity verification rejected"),
        ("package-hash", "package size or digest mismatch"),
        ("control-version", "signed package lookup or control identity rejected"),
        ("control-arch", "signed package lookup or control identity rejected"),
        ("ambiguous", "signed package lookup or control identity rejected"),
        ("expired", "signed metadata expired"),
    ):
        with fixture(case) as (work, _reviewed, args, env, _requests, _remote):
            result = run(args, env)
            assert result.returncode != 0, case
            assert expected in result.stderr, (case, result.stderr)
            assert not (work / "capsule.tar").exists(), case
            assert not list(work.glob(".prefetch-*")), case


def test_redirects_unknown_tls_and_bounded_transfers_never_publish() -> None:
    for case in ("redirect", "same-origin-redirect", "oversize", "timeout", "untrusted-tls", "hostname"):
        with fixture(case) as (work, _reviewed, args, env, requests, _remote):
            if case == "untrusted-tls":
                args[args.index("--ca-file") + 1] = str(work / "untrusted-ca.pem")
            result = run(args, env)
            assert result.returncode != 0, case
            assert "exact HTTPS GET failed" in result.stderr, (case, result.stderr)
            assert not (work / "capsule.tar").exists(), case
            assert all(not url.endswith("/redirected") for url, _authenticated in requests), case
            assert not list(work.glob(".prefetch-*")), case


def test_missing_remote_object_is_named_and_leaves_no_capsule_or_partial_files() -> None:
    with fixture("missing-object") as (work, reviewed, args, env, requests, _remote):
        private = work / "private"
        private.mkdir(mode=0o700)
        args[args.index("--output") + 1] = str(private / "capsule.tar")
        missing = next(row for row in reviewed["objects"] if row["kind"] == "deb"
                       and row["urls"][0].startswith("https://apt.ceralive.tv/"))
        result = run(args, env)
        assert result.returncode != 0
        assert (f"exact HTTPS GET failed for object {missing['sha256']} at {missing['urls'][0]} (HTTP 404"
                in result.stderr), result.stderr
        assert (missing["urls"][0], True) in requests
        assert str(work / "client.pem") not in result.stderr
        assert str(work / "client.key") not in result.stderr
        for name in ("client.pem", "client.key"):
            assert str(work / IDENTITY / name) not in result.stdout + result.stderr
        # No capsule, partial download, staged archive or temporary directory survives.
        assert list(private.iterdir()) == []


def test_unapproved_objects_and_client_origins_are_rejected_before_requests() -> None:
    for case, expected in (
        ("origin", "client identity requires one exact independently approved origin"),
        ("traversal", "sealed URL path traversal"),
        ("encoded-traversal", "sealed URL path traversal"),
        ("encoded-separator", "sealed objects require exact HTTPS origin URLs"),
        ("arbitrary-url", "sealed objects require exact HTTPS origin URLs"),
        ("extra-metadata", "undeclared network metadata"),
        ("missing-package", "each package object requires one reviewed identity"),
        ("duplicate-url", "ambiguous reviewed object or URL"),
    ):
        with fixture() as (work, reviewed, args, env, requests, _remote):
            selected = next(row for row in reviewed["objects"] if row["kind"] == "deb")
            if case == "origin":
                config = work / "client-identities"
                config.write_text(config.read_text().replace("apt.ceralive.tv", "other.example"))
            elif case in ("traversal", "encoded-traversal", "encoded-separator"):
                selected["urls"] = ["https://apt.ceralive.tv/" + {
                    "traversal": "../key", "encoded-traversal": "%2e%2e/key",
                    "encoded-separator": "pool%2fkey"}[case]]
            elif case == "arbitrary-url":
                selected["urls"] = ["http://repo.example/package.deb"]
            elif case == "extra-metadata":
                selected["kind"] = "apt-metadata"
                reviewed["packages"] = reviewed["packages"][1:]
            elif case == "missing-package":
                reviewed["packages"] = reviewed["packages"][1:]
            elif case == "duplicate-url":
                selected["urls"] += selected["urls"]
            (work / "reviewed.json").write_text(json.dumps(reviewed))
            result = run(args, env)
            assert result.returncode != 0, case
            assert expected in result.stderr, (case, result.stderr)
            assert requests == [], case
            assert not (work / "capsule.tar").exists(), case


def test_mtls_is_required_without_using_any_host_identity() -> None:
    with fixture() as (work, _reviewed, args, env, requests, _remote):
        index = args.index("--client-identity-config")
        del args[index:index + 2]
        result = run(args, env)
        assert result.returncode != 0
        assert requests == [("https://apt.ceralive.tv/dists/stable/binary-arm64/Packages.gz", False)]
        assert not (work / "capsule.tar").exists()


def test_client_identity_config_refuses_unsafe_files_and_invalid_bindings() -> None:
    with fixture() as (work, _reviewed, args, env, requests, _remote):
        config = work / "client-identities"
        valid = config.read_text()
        alias = work / "linked-identities"
        alias.symlink_to(config)
        fifo = work / "fifo-identities"
        os.mkfifo(fifo, mode=0o600)
        directory = work / "shared"
        directory.mkdir()
        shared = directory / config.name
        shared.hardlink_to(config)
        directory.chmod(0o770)
        for path, mode, contents, reason in (
            (alias, 0o600, valid, "symlink"), (fifo, 0o600, valid, "regular file"),
            (shared, 0o600, valid, "directory"), (config, 0o640, valid, "0600"),
            (config, 0o400, valid, "0600"), (config, 0o600, valid * 2, "duplicate"),
            (config, 0o600, valid.rstrip() + " extra", "exactly"),
            (config, 0o600, "https://apt.ceralive.tv relative /key", "absolute"),
            (config, 0o600, valid + "'", "quoting"),
        ):
            config.chmod(0o600)
            config.write_text(contents)
            config.chmod(mode)
            args[args.index("--client-identity-config") + 1] = str(path)
            result = run(args, env)
            assert result.returncode != 0 and reason in result.stderr, result.stderr
            assert IDENTITY not in result.stderr and not result.stdout
            assert requests == [] and not (work / "capsule.tar").exists()
        # Exercise a foreign st_uid without changing users or requiring chown privileges.
        fstat = os.fstat

        def foreign_owner(fd: int) -> os.stat_result:
            info = fstat(fd)
            if stat.S_ISREG(info.st_mode):
                return os.stat_result((*info[:4], info.st_uid + 1, *info[5:]))
            return info

        with patch("os.fstat", foreign_owner):
            try:
                identity_config(config)
            except StreamError as exc:
                assert "owned by the invoking user" in str(exc)
            else:
                raise AssertionError("accepted a foreign-owned identity file")


def test_legacy_client_identity_warns_and_cannot_override_config() -> None:
    with fixture() as (work, _reviewed, args, env, requests, _remote):
        args += ["--client-identity", "https://apt.ceralive.tv",
                 str(work / "client.pem"), str(work / "client.key")]
        result = run(args, env)
        assert result.returncode != 0 and "duplicate" in result.stderr and requests == []
        index = args.index("--client-identity-config")
        del args[index:index + 2]
        result = run(args, env)
        assert result.returncode == 0, result.stderr
        assert len(result.stderr.splitlines()) == 1
        assert "--client-identity-config" in result.stderr and "process arguments" in result.stderr
        assert str(work / "client.key") not in result.stderr and str(work / "client.pem") not in result.stderr
        assert any(authenticated for _, authenticated in requests)


def test_signed_package_url_cannot_authorize_another_reviewed_location() -> None:
    with fixture() as (work, reviewed, args, env, requests, _remote):
        selected = next(row for row in reviewed["objects"] if row["kind"] == "deb")
        selected["urls"] = ["https://other.example/package.deb"]
        (work / "reviewed.json").write_text(json.dumps(reviewed))
        result = run(args, env)
        assert result.returncode != 0
        assert "reviewed package differs from original signed index" in result.stderr
        assert len(requests) == 6
        assert all(not url.endswith(".deb") for url, _authenticated in requests)
        assert not (work / "capsule.tar").exists()


def test_local_input_links_size_and_hash_mismatches_never_publish() -> None:
    for case, expected in (("link", "local input is not a regular file"),
                           ("size", "local input is not a regular file"),
                           ("hash", "prefetched object size or digest mismatch")):
        with fixture() as (work, reviewed, args, env, requests, _remote):
            source_dir = work / LOCAL_PATH_CANARY
            source_dir.mkdir()
            pinned_hash = reviewed["source_bundle"]
            source = (work / pinned_hash).rename(source_dir / "source.bundle")
            row = next(row for row in reviewed["objects"] if row["kind"] == "source-bundle")
            row["path"] = str(source)
            if case == "link":
                alias = source_dir / "linked-source"
                alias.symlink_to(source)
                row["path"] = str(alias)
            else:
                data = source.read_bytes()
                source.write_bytes(data + b"changed" if case == "size" else bytes([data[0] ^ 1]) + data[1:])
            (work / "reviewed.json").write_text(json.dumps(reviewed))
            result = run(args, env)
            assert result.returncode != 0, case
            assert expected in result.stderr, (case, result.stderr)
            assert result.returncode == 1 and result.stdout == "", case
            assert LOCAL_PATH_CANARY not in result.stderr, (case, result.stderr)
            if case == "hash":
                observed = source.read_bytes()
                assert_mismatch_line(result.stderr, "source-bundle", row["length"], len(observed),
                                     pinned_hash, hashlib.sha256(observed).hexdigest())
            else:
                assert result.stderr == ("capsule preparation rejected: local input is not a regular file "
                                         "of the approved size\n"), (case, result.stderr)
            assert requests == []
            assert not (work / "capsule.tar").exists()


def test_measurement_only_debian_missing_valid_until_waiver_is_preserved() -> None:
    with fixture("debian-waiver") as (work, _reviewed, args, env, _requests, _remote):
        result = run(args, env)
        assert result.returncode == 0, result.stderr
        capsule = unpack(work / "capsule.tar", work / "imported",
                         Identity("test", "rock-5b-plus", "a" * 40, 1234, result.stdout.strip()))
        receipts = [json.loads((capsule.directory / row.sha256).read_bytes())
                    for row in capsule.objects if row.kind == "apt-metadata" and not row.urls
                    and (capsule.directory / row.sha256).read_bytes().startswith(b'{"delivery"')]
        validity = receipts[0]["metadata_validity"]["repositories"]
        assert next(row for row in validity if row["repository"] == "debian-source")["freshness"] == "NOT checked"


if __name__ == "__main__":
    for name, function in list(globals().items()):
        if name.startswith("test_"):
            function()
            print("PASS", name)
