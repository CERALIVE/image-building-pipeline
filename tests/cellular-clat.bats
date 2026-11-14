#!/usr/bin/env bats

@test "RFC 7050 discovery and link lifecycle admission" {
  run python3 "${BATS_TEST_DIRNAME}/clat-test.py"
  [ "$status" -eq 0 ]
}

@test "image installs Debian tayga and the independent CLAT service" {
  root="${BATS_TEST_DIRNAME}/.."
  grep -qx tayga "$root/manifests/packages/shared.list"
  grep -q setup_cellular_clat "$root/mkosi/mkosi.images/runtime/mkosi.postinst.chroot"
  grep -q setup_cellular_clat "$root/mkosi/customize/services.sh"
  grep -q 'enable_service ceralive-clat.service' "$root/mkosi/customize/postinst.d/networking.sh"
  grep -q 'CapabilityBoundingSet=.*CAP_KILL' "$root/mkosi/runtime/ceralive-clat.service"
  grep -q 'NoNewPrivileges=yes' "$root/mkosi/runtime/ceralive-clat.service"
  grep -q 'ExecStopPost=.*--cleanup' "$root/mkosi/runtime/ceralive-clat.service"
}
