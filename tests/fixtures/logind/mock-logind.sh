#!/bin/bash
set -eu
mount --make-rprivate /
root=/var/tmp/logind-contract/sys
mkdir -p "$root/devices/platform/power/input/input0/event0" "$root/class/input" "$root/dev/char"
event="$root/devices/platform/power/input/input0/event0"
printf 'MAJOR=13\nMINOR=64\nDEVNAME=input/event0\n' > "$event/uevent"
echo 13:64 > "$event/dev"
ln -sfn /sys/class/input "$event/subsystem"
ln -sfn ../../devices/platform/power/input/input0/event0 "$root/class/input/event0"
ln -sfn ../../devices/platform/power/input/input0/event0 "$root/dev/char/13:64"
mount --bind "$root" /sys
mkdir -p /dev/input /run/udev/data /run/udev/tags/power-switch
[ -p /dev/input/event0 ] || mkfifo /dev/input/event0
: > /run/udev/tags/power-switch/c13:64
printf 'I:1\nE:ID_INPUT=1\nE:ID_INPUT_KEY=1\nG:power-switch\nQ:power-switch\n' > /run/udev/data/c13:64
export LD_PRELOAD=/var/tmp/logind-contract/input-ioctl.so
exec /usr/lib/systemd/systemd-logind
