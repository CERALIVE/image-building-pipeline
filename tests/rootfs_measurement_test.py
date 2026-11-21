#!/usr/bin/env python3
"""Purpose and assembly tests use synthetic public bytes and tiny command stand-ins."""

import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import io
import tarfile
import runpy
import sys
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
DER = b"synthetic-public-root"


def test_measurement_requires_shipping_production_sealed_inputs_and_exact_public_root() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        work = Path(temporary)
        (work / "bin").mkdir()
        openssl = work / "bin/openssl"
        openssl.write_text("#!/bin/sh\ncase \"$1\" in x509) printf synthetic-public-root;; verify) exit 0;; *) exit 99;; esac\n")
        openssl.chmod(0o755)
        root = work / "public-fixture.pem"
        root.write_text("-----BEGIN CERTIFICATE-----\nRklYVFVSRQ==\n-----END CERTIFICATE-----\n")
        sealed = work / "sealed"
        sealed.mkdir()
        for file in ("inventory.json", "trust.json"):
            (sealed / file).write_text("{}\n")
        env = {"PATH": str(work / "bin") + ":" + os.environ["PATH"], "HOME": str(work), "TMPDIR": str(work),
               "CERALIVE_BUILD_MODE": "production", "INSTALL_BOOT_BSP": "1", "MKOSI_NATIVE": "0",
               "CERALIVE_SEALED_INPUTS": str(sealed), "CERALIVE_SEALED_INPUT_SHA256": "b" * 64,
               "RAUC_KEYRING_FILE": str(root),
               "CERALIVE_MEASUREMENT_ROOT_SHA256": hashlib.sha256(DER).hexdigest()}
        script = ('die() { printf "%s\\n" "$*" >&2; exit 1; }; '
                  'source "$1/lib/rauc-pki-contract.sh"; source "$1/lib/rootfs-measurement.sh"; '
                  'rootfs_measurement_preflight; '
                  '[[ "$CERALIVE_BUILD_MODE" == production && "$CERALIVE_BUILD_PURPOSE" == rootfs-measurement ]]; '
                  '[[ "$BSP_DRIFT_STRICT" == 1 && "$CERALIVE_REQUIRE_KERNEL_APT" == 1 ]]')
        cases = ({}, {"CERALIVE_BUILD_MODE": "development"}, {"INSTALL_BOOT_BSP": "0"},
                 {"CERALIVE_DEBUG_IMAGE": "1"}, {"CERALIVE_BENCH_LABELS": "1"},
                 {"BSP_DRIFT_STRICT": "0"}, {"CERALIVE_REQUIRE_KERNEL_APT": "0"},
                 {"CERALIVE_MEASUREMENT_ROOT_SHA256": "c" * 64},
                 {"CERALIVE_SEALED_INPUTS": ""}, {"APT_CLIENT_KEY_B64": "synthetic"},
                 {"RAUC_RELEASE_PKI_TAR_B64": "synthetic"},
                 {"CERALIVE_RAUC_PKI_DIR": "/nonexistent-private-input"}, {"DRY_RUN": "1"})
        for changes in cases:
            result = subprocess.run(["bash", "-euo", "pipefail", "-c", script, "_", str(ROOT)],
                                    env=env | changes, capture_output=True, text=True, timeout=10)
            assert (result.returncode == 0) == (not changes), (changes, result.stderr)
        root.write_text(root.read_text() + "-----BEGIN PRIVATE KEY-----\nSYNTHETIC\n-----END PRIVATE KEY-----\n")
        result = subprocess.run(["bash", "-euo", "pipefail", "-c", script, "_", str(ROOT)],
                                env=env, capture_output=True, text=True, timeout=10)
        assert result.returncode != 0 and "exactly one public certificate" in result.stderr


def test_normal_full_build_still_requires_a_private_signer_before_any_stage() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        env = {"PATH": os.environ["PATH"], "HOME": temporary, "TMPDIR": temporary,
               "CERALIVE_BUILD_MODE": "production"}
        result = subprocess.run(["bash", str(ROOT / "lib/orchestrate.sh"), "--board", "rock-5b-plus",
                                 "--manifest", str(ROOT / "manifests/boards/rock-5b-plus.yaml")],
                                env=env, capture_output=True, text=True, timeout=10)
        assert result.returncode != 0
        assert "production RAUC PKI requires explicit" in result.stderr
        assert "[1/9]" not in result.stdout


def test_measurement_cli_refuses_board_matrices_and_kernel_only_purposes() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        env = {"PATH": os.environ["PATH"], "HOME": temporary, "TMPDIR": temporary}
        for args in (("--all", "--rootfs-measurement"),
                     ("rock-5b-plus", "--kernel-only", "--rootfs-measurement")):
            result = subprocess.run(["bash", str(ROOT / "build"), *args], env=env,
                                    capture_output=True, text=True, timeout=10)
            assert result.returncode != 0 and "requires one board and a separate purpose" in result.stderr


def test_measurement_reuses_raw_assembly_and_skips_signing_and_compression() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        work = Path(temporary)
        (work / "images").mkdir()
        (work / "rootfs").mkdir()
        assembler = work / "assembler"
        assembler.write_text("#!/bin/bash\nwhile (($#)); do if [[ $1 == --output ]]; then printf RAW >\"$2\"; shift 2; else shift; fi; done\n")
        installer = work / "installer"
        installer.write_text("#!/bin/sh\nprintf BOOT >\"$2/boot.scr\"\nprintf SHA >\"$2/boot.scr.sha256\"\n")
        forbidden = work / "forbidden"
        forbidden.write_text("#!/bin/sh\nprintf 'FORBIDDEN SIGNING OR COMPRESSION\\n' >&2\nexit 99\n")
        for file in (assembler, installer, forbidden):
            file.chmod(0o755)
        script = '''
log_info() { :; }; log_success() { :; }; die() { printf '%s\\n' "$*" >&2; exit 1; }
source "$1/lib/stages/assemble.sh"
out_dir="$2/images"; ts=fixture; board=fixture; variant=default
rootfs_tree="$2/rootfs"; bsp_dir="$2"; INSTALL_BOOT_BSP=1
RAUC_BOOTLOADER_ADAPTER=custom; BOARD_ID=fixture; SINGLE_SLOT_FALLBACK=false
ASSEMBLE_DISK_SH="$2/assembler"; INSTALL_BOOT_SH="$2/installer"
BUILD_BUNDLE_SH="$2/forbidden"; SEAL_RAW_CANDIDATE_SH="$2/forbidden"
CERALIVE_BUILD_PURPOSE=rootfs-measurement
stage_assemble
[[ "$( <"$out_dir/fixture.raw" )" == RAW ]]
[[ "$( <"$out_dir/measurement-slots/boot.scr" )" == BOOT ]]
[[ ! -e "$out_dir/fixture.raucb" && ! -e "$out_dir/fixture.raw.xz" ]]
'''
        result = subprocess.run(["bash", "-euo", "pipefail", "-c", script, "_", str(ROOT), str(work)],
                                env={"PATH": os.environ["PATH"], "HOME": str(work), "TMPDIR": str(work)},
                                capture_output=True, text=True, timeout=10)
        assert result.returncode == 0, result.stderr
        assert "FORBIDDEN" not in result.stderr


def test_sealed_mediamtx_reuses_recipe_hash_gate_without_network() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        work = Path(temporary)
        runtime = work / "runtime/rtmp-gateway"
        runtime.mkdir(parents=True)
        objects = work / ".image-inputs"
        objects.mkdir()
        stream = io.BytesIO()
        with tarfile.open(fileobj=stream, mode="w:gz") as archive:
            data = b"synthetic public binary"
            header = tarfile.TarInfo("mediamtx")
            header.size = len(data)
            archive.addfile(header, io.BytesIO(data))
        digest = hashlib.sha256(stream.getvalue()).hexdigest()
        (objects / digest).write_bytes(stream.getvalue())
        (runtime / "mediamtx.recipe.conf").write_text(
            f"MEDIAMTX_VERSION=fixture\nMEDIAMTX_URL_TEMPLATE=https://invalid.example/fixture\nMEDIAMTX_SHA256_arm64={digest}\n")
        for name in ("mediamtx.yml", "ceralive-rtmp-gateway.service"):
            (runtime / name).write_text("fixture\n")
        script = '''
log() { :; }; die() { printf '%s\\n' "$*" >&2; exit 1; }
curl() { printf 'NETWORK ATTEMPT\\n' >&2; exit 99; }
systemctl() { printf 'FORBIDDEN HOST SERVICE CALL\\n' >&2; exit 99; }
source "$1/mkosi/customize/postinst.d/services.sh"
enable_service() { printf '%s\\n' "$1" >"${MEDIAMTX_DESTROOT}/enabled"; }
CERALIVE_RUNTIME_SRC="$2/runtime"; MEDIAMTX_ARCH=arm64; MEDIAMTX_DESTROOT="$2/result"
CERALIVE_SEALED_MEDIAMTX_SHA256="$3"
setup_rtmp_gateway
'''
        for selected in (digest, "c" * 64):
            result = subprocess.run(["bash", "-euo", "pipefail", "-c", script, "_",
                                     str(ROOT), str(work), selected],
                                    env={"PATH": os.environ["PATH"], "HOME": str(work), "TMPDIR": str(work)},
                                    capture_output=True, text=True, timeout=10)
            assert "NETWORK ATTEMPT" not in result.stderr
            if selected == digest:
                assert result.returncode == 0, result.stderr
                assert (work / "result/usr/local/bin/mediamtx").read_bytes() == b"synthetic public binary"
                assert (work / "result/enabled").read_text() == "ceralive-rtmp-gateway.service\n"
            else:
                assert result.returncode != 0 and "differs from the public recipe pin" in result.stderr


def test_measurement_requires_approved_manifest_kernel_shipping_variant_and_both_slots() -> None:
    script = '''
die() { printf '%s\\n' "$*" >&2; exit 1; }
source "$1/lib/rootfs-measurement.sh"
HERE="$1/lib"; family_manifest="$1/manifests/families/rk3588.yaml"
FAMILY=rk3588; ARCH=arm64; CHECK_RELEASE_VARIANT_SH="$1/ci/check-release-variant.sh"; variant=default
board=rock-5b-plus; KERNEL_PACKAGES=linux-image-7.2.0-ceralive-rk3588
KERNEL_SOURCE_PACKAGE_VERSION="$2"; KERNEL_VARIANT="$3"; SINGLE_SLOT_FALLBACK="$4"
ARCH="$5"; CERALIVE_SEALED_INPUTS="$6"
rootfs_measurement_resolved
'''
    with tempfile.TemporaryDirectory() as temporary:
        sealed = Path(temporary)
        for selected, approved, variant, slots, arch, valid_hash, success in (
            ("7.2.0-ceralive8", "7.2.0-ceralive8", "edge", "false", "arm64", True, True),
            ("7.2.0-ceralive9", "7.2.0-ceralive9", "edge", "false", "arm64", True, True),
            ("7.2.0-ceralive8", "7.2.0-ceralive9", "edge", "false", "arm64", True, False),
            ("7.2.0-ceralive8", "7.2.0-ceralive8", "edge-test", "false", "arm64", True, False),
            ("7.2.0-ceralive8", "7.2.0-ceralive8", "vendor", "false", "arm64", True, False),
            ("7.2.0-ceralive8", "7.2.0-ceralive8", "edge", "true", "arm64", True, False),
            ("7.2.0-ceralive8", "7.2.0-ceralive8", "edge", "false", "amd64", True, False),
            ("7.2.0-ceralive8", "7.2.0-ceralive8", "edge", "false", "arm64", False, False),
        ):
            obj = json.dumps({
                "package": "linux-image-7.2.0-ceralive-rk3588", "version": approved,
                "arch": "arm64", "kernel_release": "7.2.0-ceralive-rk3588",
                "deb_sha256": "a" * 64, "input_fingerprint": "b" * 64, "kernel_epoch": 123,
                "validated_boards": ["orange-pi-5-plus", "rock-5b-plus"],
                "builder_closure": {"base_image": "fixture", "packages": ["gcc=1"],
                                    "compiler": "gcc", "dockerfile_sha256": "c" * 64},
            }).encode()
            digest = hashlib.sha256(obj).hexdigest()
            (sealed / "trust.json").write_text(json.dumps({"kernel_metadata": {"kernel-artifact.json": digest}}))
            (sealed / digest).write_bytes(obj if valid_hash else obj + b"\n")
            args = (selected, variant, slots, arch, str(sealed))
            result = subprocess.run(["bash", "-euo", "pipefail", "-c", script, "_", str(ROOT), *args],
                                    env={"PATH": os.environ["PATH"], "HOME": temporary, "TMPDIR": temporary},
                                    capture_output=True, text=True, timeout=10)
            assert (result.returncode == 0) == success, (selected, approved, args, result.stderr)


def test_slot_retention_keeps_the_actual_writer_output_after_scratch_cleanup() -> None:
    script = '''
die() { printf '%s\\n' "$*" >&2; exit 1; }; log_info() { :; }; log_success() { :; }
source "$1/lib/disk/slot.sh"
assert_free_space() { :; }; register_scratch() { :; }; discard_scratch() { rm -- "$1"; }
part_field() { if [[ "$3" == 'First sector' ]]; then printf 0; else printf 8388608; fi; }
make_slot_image() { printf POPULATED >"$2"; }
SECTOR=512; CERALIVE_BUILD_PURPOSE=rootfs-measurement
CERALIVE_RETAIN_SLOT_DIR="$2/retained"
mkdir "$2/tree" "$CERALIVE_RETAIN_SLOT_DIR"
populate_rootfs_slot "$2/raw" "$2/tree" 2 rootfs_a
[[ "$( <"$2/retained/rootfs_a.ext4" )" == POPULATED ]]
( cd "$2/retained"; sha256sum -c rootfs_a.ext4.sha256 )
'''
    with tempfile.TemporaryDirectory() as temporary:
        result = subprocess.run(["bash", "-euo", "pipefail", "-c", script, "_", str(ROOT), temporary],
                                env={"PATH": os.environ["PATH"], "HOME": temporary, "TMPDIR": temporary},
                                capture_output=True, text=True, timeout=10)
        assert result.returncode == 0, result.stderr
        assert not list(Path(temporary).glob(".rootfs-slot.*"))


def test_measurement_receipt_retains_the_authenticated_metadata_freshness_waiver() -> None:
    from bootstrap_metadata_test import bootstrap_fixture
    module = runpy.run_path(str(ROOT / "lib/sealed-inputs.py"))
    writer = runpy.run_path(str(ROOT / "lib/rootfs-measurement.py"))["main"]
    with bootstrap_fixture("missing-until") as directory:
        env = {"CERALIVE_BUILD_PURPOSE": "rootfs-measurement", "CERALIVE_SEALED_INPUTS": str(directory),
               "CERALIVE_BOARD": "fixture", "CERALIVE_IMAGE_BUILD_COMMIT": "a" * 40,
               "SOURCE_DATE_EPOCH": "1", "CERALIVE_SEALED_INPUT_SHA256": "b" * 64,
               "RAUC_ROOT_SHA256": "c" * 64, "KERNEL_SOURCE_PACKAGE_VERSION": "7.2.0-ceralive8"}
        slots = directory / "slots"
        slots.mkdir()
        for name in ("rootfs.tar", "packages.lock.json", "slots/rootfs_a.ext4", "slots/rootfs_b.ext4",
                     "slots/rootfs_a.reserve", "slots/rootfs_b.reserve", "slots/rootfs_a.header",
                     "slots/rootfs_b.header", "slots/boot.scr", "slots/boot.scr.sha256"):
            (directory / name).write_bytes(b"tiny artifact fixture")
        stat = Path.stat
        def slot_stat(path, *args, **kwargs):
            values = stat(path, *args, **kwargs)
            if path.parent == slots and path.suffix == ".ext4":
                fields = list(values)
                fields[6] = 4096 * 1024 * 1024
                return os.stat_result(fields)
            return values
        output = directory / "measurement.json"
        argv = ["rootfs-measurement.py", str(output), str(directory / "rootfs.tar"),
                str(directory / "packages.lock.json"), str(slots)]
        with patch.dict(os.environ, env):
            module["mirror_validities"](directory)
            metadata = json.loads((directory / "metadata-validity.json").read_text())
            with patch.object(sys, "argv", argv), patch.object(Path, "stat", slot_stat):
                writer()
        receipt = json.loads(output.read_text())
        assert receipt["metadata_validity"] == metadata
        assert receipt["metadata_validity"]["repositories"][0]["freshness_checked"] is False


if __name__ == "__main__":
    tests = [test for name, test in list(globals().items()) if name.startswith("test_")]
    for test in tests:
        test()
        print(f"PASS {test.__name__}")
    print(f"rootfs measurement: {len(tests)} passed")
