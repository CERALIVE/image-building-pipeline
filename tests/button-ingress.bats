#!/usr/bin/env bats
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"; }
@test "button ingress: interface identity, hostile metadata, device bind and generation fences" {
  run python3 "$ROOT/tests/button-ingress-contract.py"
  [ "$status" -eq 0 ]
}
@test "button ingress: installer stages front door and fences backend fallback ports" {
  run bash -e -c '
    source "$1/mkosi/customize/postinst-lib.sh"
    log() { :; }; mask_service() { [[ "$1" == nginx.service ]]; }
    enable_service() { [[ "$1" == ceralive-button-ingress.service ]]; }
    export CERALIVE_RUNTIME_SRC="$1/mkosi/runtime" BUTTON_INGRESS_ROOT="$2"
    setup_button_ingress
    test -f "$2/usr/local/lib/ceralive-button-ingress/ingress.py"
    grep -q "Environment=PORT=18080" "$2/etc/systemd/system/ceralive.service.d/50-button-ingress.conf"
    grep -q "SocketBindDeny=ipv6:tcp:80" "$2/etc/systemd/system/ceralive.service.d/50-button-ingress.conf"
    grep -q "CapabilityBoundingSet=CAP_NET_RAW CAP_NET_BIND_SERVICE" "$2/etc/systemd/system/ceralive-button-ingress.service"
    grep -q "iifname != \"lo\" tcp dport 18080 drop" "$2/usr/local/lib/ceralive-button-ingress/backend.nft"
  ' _ "$ROOT" "$BATS_TEST_TMPDIR/root"
  [ "$status" -eq 0 ]
  grep -q 'setup_button_ingress' "$ROOT/mkosi/customize/services.sh"
  grep -q 'setup_button_ingress' "$ROOT/mkosi/mkosi.images/runtime/mkosi.postinst.chroot"
}
@test "button ingress: real kernel device binding in isolated namespaces" {
  if ! sudo -n unshare -n true 2>/dev/null; then
    [ "${CERALIVE_RUN_BUTTON_NETNS:-skip}" != required ] || return 1
    skip "passwordless isolated network namespaces unavailable"
  fi
  run sudo -n unshare -n python3 "$ROOT/tests/button-ingress-kernel.py"
  [ "$status" -eq 0 ]
}
