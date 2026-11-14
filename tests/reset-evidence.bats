#!/usr/bin/env bats
setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}
@test "kernel device tree reservation compiles and applies without base symbols" {
  { printf '/dts-v1/; /plugin/; / { fragment@0 { target-path = "/"; __overlay__ {\n'
    sed '1,2d;$d' "$REPO/manifests/kernel/rk3588-ramoops.dtsi"
    printf '}; }; };\n'
  } > "$BATS_TEST_TMPDIR/overlay.dts"
  dtc -@ -I dts -O dtb -o "$BATS_TEST_TMPDIR/overlay.dtbo" "$BATS_TEST_TMPDIR/overlay.dts"
  printf '/dts-v1/; / { #address-cells = <2>; #size-cells = <2>; reserved-memory { #address-cells = <2>; #size-cells = <2>; ranges; }; };' > "$BATS_TEST_TMPDIR/base.dts"
  dtc -I dts -O dtb -o "$BATS_TEST_TMPDIR/base.dtb" "$BATS_TEST_TMPDIR/base.dts"
  fdtoverlay -i "$BATS_TEST_TMPDIR/base.dtb" -o "$BATS_TEST_TMPDIR/result.dtb" "$BATS_TEST_TMPDIR/overlay.dtbo"
  node=/reserved-memory/ramoops@1f000000
  [ "$(fdtget -tx "$BATS_TEST_TMPDIR/result.dtb" "$node" reg)" = '0 1f000000 0 100000' ]
  [ "$(fdtget -tx "$BATS_TEST_TMPDIR/result.dtb" "$node" record-size)" = 20000 ]
  [ "$(fdtget -tx "$BATS_TEST_TMPDIR/result.dtb" "$node" console-size)" = 80000 ]
  [ "$(fdtget -tx "$BATS_TEST_TMPDIR/result.dtb" "$node" max-reason)" = 2 ]
}
@test "kernel build injects the reservation only into both Rock board sources" {
  tree="$BATS_TEST_TMPDIR/linux/arch/arm64/boot/dts/rockchip"
  mkdir -p "$tree"
  for board in rk3588-rock-5b rk3588-rock-5b-plus rk3588-orangepi-5-plus; do
    printf '/dts-v1/; / { #address-cells = <2>; #size-cells = <2>; };\n' > "$tree/$board.dts"
  done
  bash "$REPO/lib/kernel/ramoops.sh" "$BATS_TEST_TMPDIR/linux" "$REPO/manifests/kernel/rk3588-ramoops.dtsi"
  bash "$REPO/lib/kernel/ramoops.sh" "$BATS_TEST_TMPDIR/linux" "$REPO/manifests/kernel/rk3588-ramoops.dtsi"
  for board in rk3588-rock-5b rk3588-rock-5b-plus; do
    [ "$(grep -c '/include/' "$tree/$board.dts")" = 1 ]
    dtc -I dts -O dtb -o "$BATS_TEST_TMPDIR/$board.dtb" "$tree/$board.dts"
    [ "$(fdtget -ts "$BATS_TEST_TMPDIR/$board.dtb" /reserved-memory/ramoops@1f000000 compatible)" = ramoops ]
  done
  run grep -q ramoops "$tree/rk3588-orangepi-5-plus.dts"
  [ "$status" -eq 1 ]
  grep -q 'bash /in/ramoops.sh /src/linux /in/ramoops.dtsi' "$REPO/lib/build-kernel.sh"
  grep -q 'rk3588-ramoops.dtsi' "$REPO/lib/kernel/artifact-cache.sh"
  ! grep -q ramoops "$REPO/mkosi/platform/boot/boot.scr.cmd"
}
@test "stock pstore installer provides persistent storage, config and ordering" {
  export CERALIVE_RUNTIME_SRC="$REPO/mkosi/runtime"
  export PSTORE_DESTROOT="$BATS_TEST_TMPDIR/root"
  export CALLS="$BATS_TEST_TMPDIR/calls"
  run bash -c 'source "$1/mkosi/customize/postinst.d/services.sh"; enable_service() { echo "enable $*" >> "$CALLS"; }; mask_service() { echo "mask $*" >> "$CALLS"; }; setup_reset_evidence' _ "$REPO"
  [ "$status" -eq 0 ]
  [ -x "$PSTORE_DESTROOT/usr/lib/ceralive/ceralive-pstore-rotate" ]
  grep -qx 'Storage=external' "$PSTORE_DESTROOT/etc/systemd/pstore.conf.d/60-ceralive.conf"
  grep -qx 'Unlink=yes' "$PSTORE_DESTROOT/etc/systemd/pstore.conf.d/60-ceralive.conf"
  grep -qx 'RequiresMountsFor=/data/ceralive/pstore' "$PSTORE_DESTROOT/etc/systemd/system/systemd-pstore.service.d/60-ceralive.conf"
  grep -qx 'BindPaths=/data/ceralive/pstore:/var/lib/systemd/pstore' "$PSTORE_DESTROOT/etc/systemd/system/systemd-pstore.service.d/60-ceralive.conf"
  grep -qx 'd /data/ceralive/pstore 0700 root root -' "$PSTORE_DESTROOT/etc/tmpfiles.d/ceralive-pstore.conf"
  grep -qx 'After=data.mount' "$PSTORE_DESTROOT/etc/systemd/system/systemd-tmpfiles-setup.service.d/60-ceralive-pstore.conf"
  grep -qx 'enable systemd-pstore.service' "$CALLS"
  run grep -q mask "$CALLS"
  [ "$status" -eq 1 ]
  [ ! -e "$REPO/mkosi/runtime/ceralive-reset-evidence.sh" ]
  [ ! -e "$REPO/mkosi/runtime/ceralive-reset-evidence.service" ]
}
@test "tmpfiles creates private persistent storage and stock unit has no ordering cycle" {
  root="$BATS_TEST_TMPDIR/root"
  mkdir -p "$root"
  sed "s/root root/$(id -u) $(id -g)/" "$REPO/mkosi/runtime/ceralive-pstore.tmpfiles.conf" > "$BATS_TEST_TMPDIR/tmpfiles.conf"
  systemd-tmpfiles --root="$root" --create "$BATS_TEST_TMPDIR/tmpfiles.conf"
  [ "$(stat -c %a "$root/data/ceralive/pstore")" = 700 ]
  mkdir -p "$root/etc/systemd/system/systemd-pstore.service.d"
  sed "s|/usr/lib/ceralive/ceralive-pstore-rotate|$REPO/mkosi/runtime/ceralive-pstore-rotate.sh|" "$REPO/mkosi/runtime/ceralive-pstore.service.conf" > "$root/etc/systemd/system/systemd-pstore.service.d/60-ceralive.conf"
  mkdir -p "$root/etc/systemd/system/systemd-tmpfiles-setup.service.d"
  cp "$REPO/mkosi/runtime/ceralive-pstore-tmpfiles.service.conf" "$root/etc/systemd/system/systemd-tmpfiles-setup.service.d/60-ceralive-pstore.conf"
  printf '[Unit]\nDefaultDependencies=no\nAfter=systemd-fsck@dev-disk-by-label-data.service\nRequires=systemd-fsck@dev-disk-by-label-data.service\nBefore=systemd-growfs@data.service\nWants=systemd-growfs@data.service\n[Mount]\nWhat=/dev/disk/by-label/data\nWhere=/data\nType=ext4\nOptions=defaults,noatime,nofail,x-systemd.growfs\n' > "$root/etc/systemd/system/data.mount"
  printf '[Unit]\nDefaultDependencies=no\nBefore=local-fs.target\nRequiresMountsFor=/data/log\n[Mount]\nWhat=/data/log\nWhere=/var/log\nOptions=bind\n' > "$root/etc/systemd/system/var-log.mount"
  SYSTEMD_UNIT_PATH="$root/etc/systemd/system:/usr/lib/systemd/system" systemd-analyze --man=no verify systemd-pstore.service systemd-tmpfiles-setup.service data.mount var-log.mount
}
@test "documented stock output reader handles empty and populated fixture trees without writes" {
  store="$BATS_TEST_TMPDIR/pstore"
  mkdir -p "$store/123"
  run find "$store" -type f -name '*ramoops*' -exec tail -v -n +1 -- '{}' +
  [ "$status" = 0 ]; [ -z "$output" ]
  printf 'panic fixture\n' > "$store/123/dmesg-ramoops-0"
  printf 'console fixture\n' > "$store/console-ramoops-0"
  before="$(find "$store" -type f -exec sha256sum '{}' +)"
  run find "$store" -type f -name '*ramoops*' -exec tail -v -n +1 -- '{}' +
  [ "$status" = 0 ]; [[ "$output" == *'panic fixture'* && "$output" == *'console fixture'* ]]
  [[ "$output" == *"==> $store/123/dmesg-ramoops-0 <=="* ]]
  [[ "$output" == *"==> $store/console-ramoops-0 <=="* ]]
  [ "$before" = "$(find "$store" -type f -exec sha256sum '{}' +)" ]
  grep -Fq -- "-name '*ramoops*' -exec tail -v -n +1" "$REPO/docs/reset-evidence.md"
}

@test "consecutive stock archive runs preserve the crash before a clean warm reboot" {
  store="$BATS_TEST_TMPDIR/store"
  source="$BATS_TEST_TMPDIR/source"
  mkdir -p "$store" "$source"
  printf 'panic console\n' > "$source/console-ramoops-0"
  printf 'panic record\n' > "$source/dmesg-ramoops-0"
  /usr/lib/systemd/systemd-pstore "$source" "$store"
  [ ! -e "$source/console-ramoops-0" ]
  # Run the same ordered pre-step used by the service.
  helper="$REPO/mkosi/runtime/ceralive-pstore-rotate.sh"
  bash "$helper" "$store"
  [ ! -e "$store/dmesg-ramoops-0" ]
  [ ! -e "$store/console-ramoops-0" ]
  printf 'clean boot console\n' > "$source/console-ramoops-0"
  printf 'second panic\n' > "$source/dmesg-ramoops-0"
  /usr/lib/systemd/systemd-pstore "$source" "$store"
  grep -rx 'panic console' "$store"
  grep -rx 'panic record' "$store"
  grep -qx 'clean boot console' "$store/console-ramoops-0"
  grep -qx 'second panic' "$store/dmesg-ramoops-0"
}

@test "rotation bounds retained generations and leaves an empty archive alone" {
  store="$BATS_TEST_TMPDIR/store"
  mkdir -p "$store"
  helper="$REPO/mkosi/runtime/ceralive-pstore-rotate.sh"
  bash "$helper" "$store"
  [ ! -d "$store/history" ]
  for i in $(seq 1 35); do
    printf 'crash %s\n' "$i" > "$store/console-ramoops-0"
    bash "$helper" "$store"
  done
  [ "$(find "$store/history" -mindepth 1 -maxdepth 1 -type d | wc -l)" = 31 ]
  run grep -rx 'crash 1' "$store"
  [ "$status" -eq 1 ]
  grep -rx 'crash 35' "$store"
  grep -qx 'ExecStartPre=/usr/lib/ceralive/ceralive-pstore-rotate' "$REPO/mkosi/runtime/ceralive-pstore.service.conf"
}
@test "stock pstore retains source records when archive creation fails" {
  source="$BATS_TEST_TMPDIR/source"
  mkdir -p "$source"
  printf 'panic console\n' > "$source/console-ramoops-0"
  # A regular file blocks destination creation without touching host mounts.
  touch "$BATS_TEST_TMPDIR/blocked"
  /usr/lib/systemd/systemd-pstore "$source" "$BATS_TEST_TMPDIR/blocked/archive" || :
  grep -qx 'panic console' "$source/console-ramoops-0"
}

@test "rotation trims oversized historical collections" {
  store="$BATS_TEST_TMPDIR/store"
  mkdir -p "$store/history/0000000001" "$store/history/0000000002" "$store/history/0000000003"
  touch "$store/history/0000000003/.incomplete"
  truncate -s 47185920 "$store/history/0000000001/console-ramoops-0"
  printf 'keep me\n' > "$store/history/0000000002/console-ramoops-0"
  bash "$REPO/mkosi/runtime/ceralive-pstore-rotate.sh" "$store"
  [ ! -d "$store/history/0000000001" ]
  grep -qx 'keep me' "$store/history/0000000002/console-ramoops-0"
}
@test "installer rejects a missing runtime source with a useful error" {
  run bash -c 'source "$1/mkosi/customize/postinst.d/services.sh"; unset CERALIVE_RUNTIME_SRC; setup_reset_evidence' _ "$REPO"
  [ "$status" != 0 ]
  [[ "$output" == *'pstore runtime source not found'* ]]
}

clock_history() {
  store="$BATS_TEST_TMPDIR/store"
  mkdir -p "$store" "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\nprintf "%%s\\n" "$CLOCK"\n' > "$BATS_TEST_TMPDIR/bin/date"
  chmod +x "$BATS_TEST_TMPDIR/bin/date"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  for i in $(seq 1 40); do
    if [ "$1" = backward ] && [ "$i" -gt 31 ]; then
      export CLOCK=2020-01-01T00:00:00Z
    else
      export CLOCK=2026-11-14T00:00:00Z
    fi
    printf 'crash %s\n' "$i" > "$store/dmesg-ramoops-0"
    bash "$REPO/mkosi/runtime/ceralive-pstore-rotate.sh" "$store"
  done
  [ "$(find "$store/history" -mindepth 1 -maxdepth 1 -type d | wc -l)" = 31 ]
  for i in $(seq 1 9); do
    if grep -rx "crash $i" "$store"; then return 1; fi
  done
  for i in $(seq 10 40); do
    grep -qx "crash $i" "$store/history/$(printf '%010d' "$i")/dmesg-ramoops-0"
  done
  grep -qx "$CLOCK" "$store/history/0000000040/collected-at"
}
@test "sequence pruning retains newest collections after a backward clock step" {
  clock_history backward
}
@test "sequence pruning retains newest collections with a repeated boot epoch" {
  clock_history repeated
}
@test "empty and interrupted rotations do not consume extra generations" {
  store="$BATS_TEST_TMPDIR/store"
  mkdir -p "$store/history/0000000001" "$store/history/0000000002" "$store/history/0000000003"
  touch "$store/history/0000000003/.incomplete"
  touch "$store/history/0000000002/.incomplete"
  printf 'partial console\n' > "$store/history/0000000002/console-ramoops-0"
  printf 'remaining crash\n' > "$store/dmesg-ramoops-0"
  bash "$REPO/mkosi/runtime/ceralive-pstore-rotate.sh" "$store"
  [ ! -d "$store/history/0000000001" ]
  [ ! -e "$store/history/0000000002/.incomplete" ]
  [ "$(find "$store/history" -mindepth 1 -maxdepth 1 -type d | wc -l)" = 1 ]
  grep -qx 'remaining crash' "$store/history/0000000002/dmesg-ramoops-0"
  grep -qx 'partial console' "$store/history/0000000002/console-ramoops-0"
  [ ! -e "$store/dmesg-ramoops-0" ]
}
@test "sequence allocation retries a mkdir collision without merging collections" {
  store="$BATS_TEST_TMPDIR/store"
  mkdir -p "$store" "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/mkdir" <<'SH'
#!/bin/bash
if [[ "$*" == *history/0000000001* ]]; then
  /usr/bin/mkdir "$@"
  printf 'other collection\n' > history/0000000001/console-ramoops-0
  exit 1
fi
exec /usr/bin/mkdir "$@"
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/mkdir"
  printf 'new crash\n' > "$store/dmesg-ramoops-0"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" bash "$REPO/mkosi/runtime/ceralive-pstore-rotate.sh" "$store"
  grep -qx 'other collection' "$store/history/0000000001/console-ramoops-0"
  grep -qx 'new crash' "$store/history/0000000002/dmesg-ramoops-0"
}
@test "decompressed collections fit the history size budget" {
  store="$BATS_TEST_TMPDIR/store"
  mkdir -p "$store/history"
  for i in $(seq 1 31); do
    dir="$store/history/$(printf '%010d' "$i")"
    mkdir "$dir"
    truncate -s 1398104 "$dir/dmesg-ramoops-0"
  done
  bash "$REPO/mkosi/runtime/ceralive-pstore-rotate.sh" "$store"
  [ "$(find "$store/history" -mindepth 1 -maxdepth 1 -type d | wc -l)" = 31 ]
}

@test "tmpfiles clean retains epoch-dated crash records after clock synchronization" {
  root="$BATS_TEST_TMPDIR/root"
  store="$root/data/ceralive/pstore"
  mkdir -p "$store/history/0000000001"
  printf 'newest crash\n' > "$store/dmesg-ramoops-0"
  printf 'newest console\n' > "$store/console-ramoops-0"
  printf 'previous crash\n' > "$store/history/0000000001/dmesg-ramoops-0"
  printf '2020-01-01T00:00:00Z\n' > "$store/history/0000000001/collected-at"
  find "$root" -exec touch -a -m -d '2020-01-01 UTC' '{}' +
  # touch cannot backdate ctime/btime. Advance only tmpfiles' realtime clock
  # beyond those too, simulating time sync without changing the host clock.
  cc -shared -fPIC -o "$BATS_TEST_TMPDIR/clock.so" "$REPO/tests/fixtures/tmpfiles-clock.c"
  sed "s/root root/$(id -u) $(id -g)/" "$REPO/mkosi/runtime/ceralive-pstore.tmpfiles.conf" > "$BATS_TEST_TMPDIR/tmpfiles.conf"
  # Positive control: prove the old rule really deletes this fixture.
  sed 's/ -$/ 30d/' "$BATS_TEST_TMPDIR/tmpfiles.conf" > "$BATS_TEST_TMPDIR/aged.conf"
  cp -a "$root" "$BATS_TEST_TMPDIR/control"
  LD_PRELOAD="$BATS_TEST_TMPDIR/clock.so" systemd-tmpfiles --root="$BATS_TEST_TMPDIR/control" --clean "$BATS_TEST_TMPDIR/aged.conf"
  [ ! -e "$BATS_TEST_TMPDIR/control/data/ceralive/pstore/dmesg-ramoops-0" ]
  LD_PRELOAD="$BATS_TEST_TMPDIR/clock.so" systemd-tmpfiles --root="$root" --clean "$BATS_TEST_TMPDIR/tmpfiles.conf"
  grep -qx 'newest crash' "$store/dmesg-ramoops-0"
  grep -qx 'newest console' "$store/console-ramoops-0"
  grep -qx 'previous crash' "$store/history/0000000001/dmesg-ramoops-0"
  grep -qx '2020-01-01T00:00:00Z' "$store/history/0000000001/collected-at"
}

@test "history size budget ignores entries outside numbered generations" {
  store="$BATS_TEST_TMPDIR/store"
  mkdir -p "$store/history/lost+found" "$store/history/0000000001"
  truncate -s 52428800 "$store/history/lost+found/junk"
  printf 'keep me\n' > "$store/history/0000000001/dmesg-ramoops-0"
  bash "$REPO/mkosi/runtime/ceralive-pstore-rotate.sh" "$store"
  grep -qx 'keep me' "$store/history/0000000001/dmesg-ramoops-0"
  [ -f "$store/history/lost+found/junk" ]
}
