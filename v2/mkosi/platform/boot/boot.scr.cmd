# CeraLive A/B boot selector — U-Boot script SOURCE (compiled to boot.scr with
# mkimage; see install-boot.sh). Runs on the RK3588 vendor U-Boot (2017.09).
#
# WHY a boot.scr and not fw_setenv/extlinux alone (decision D3): the vendor U-Boot
# is ENV_IS_NOWHERE — `fw_setenv` does not persist, so RAUC's stock BOOT_ORDER/
# bootcount cannot live in U-Boot env. Instead the A/B state is a TEXT FILE on this
# FAT boot partition (boot_state.txt), which this script reads with `env import`,
# mutates, and writes back with `fatwrite`. extlinux.conf is static and cannot
# decrement a counter; this script is what makes failed-boot rollback work.
#
# ALGORITHM (the userspace twin lives in ceralive-boot-state.sh `boot-select`, kept
# byte-for-byte equivalent so test-fallback.sh proves this exact behaviour offline):
#   1. import board specifics (console, fdtfile) from cera_board.env  [from manifest]
#   2. import A/B state (BOOT_ORDER, BOOT_A_LEFT, BOOT_B_LEFT) from boot_state.txt
#   3. pick the first slot in BOOT_ORDER whose *_LEFT > 0   (the "primary")
#   4. DECREMENT that slot's counter and persist boot_state.txt  (so an OS that
#      never marks itself good bleeds 3->2->1->0 and the NEXT boot skips it)
#   5. if every counter is exhausted, last-resort boot the head of BOOT_ORDER
#   6. boot kernel+DTB+initrd from the chosen rootfs slot's /boot (kernel rides in
#      the rootfs per the frozen contract), root=PARTLABEL=rootfs_<a|b>
#
# devtype/devnum/partition: distro_bootcmd sets ${devtype} (mmc) + ${devnum} before
# running boot.scr; the FAT boot partition (this script + state) is partition 1, the
# rootfs slots are partitions 2 (rootfs_a) and 3 (rootfs_b) per the frozen layout.
# NO board specifics are hardcoded here — console/fdtfile come from cera_board.env.

echo "CeraLive A/B boot selector"

# --- board specifics (console, fdtfile, board_id) from the manifest-rendered file
setenv console "ttyS2,1500000"
setenv fdtfile ""
if load ${devtype} ${devnum}:1 ${loadaddr} cera_board.env; then
  env import -t ${loadaddr} ${filesize}
fi

# --- A/B boot state (defaults are safe if the file is missing/partial)
setenv BOOT_ORDER "A B"
setenv BOOT_A_LEFT 3
setenv BOOT_B_LEFT 3
if load ${devtype} ${devnum}:1 ${loadaddr} boot_state.txt; then
  env import -t ${loadaddr} ${filesize}
fi
echo "BOOT_ORDER=${BOOT_ORDER} A_LEFT=${BOOT_A_LEFT} B_LEFT=${BOOT_B_LEFT}"

# --- pick the first slot in BOOT_ORDER with attempts remaining (the primary)
setenv cera_slot ""
for s in ${BOOT_ORDER}; do
  if test "${cera_slot}" = ""; then
    setenv left 0
    if test "${s}" = "A"; then setenv left ${BOOT_A_LEFT}; fi
    if test "${s}" = "B"; then setenv left ${BOOT_B_LEFT}; fi
    if test ${left} -gt 0; then setenv cera_slot "${s}"; fi
  fi
done

# --- all counters exhausted -> last-resort boot the head of BOOT_ORDER (no decrement)
setenv cera_exhausted 0
if test "${cera_slot}" = ""; then
  setenv cera_exhausted 1
  for s in ${BOOT_ORDER}; do
    if test "${cera_slot}" = ""; then setenv cera_slot "${s}"; fi
  done
  echo "CeraLive: all slots exhausted — last-resort booting ${cera_slot}"
fi

# --- resolve the chosen slot's rootfs partition + PARTLABEL
if test "${cera_slot}" = "A"; then setenv cera_part 2; setenv cera_root rootfs_a; fi
if test "${cera_slot}" = "B"; then setenv cera_part 3; setenv cera_root rootfs_b; fi

# --- decrement the chosen slot's counter and persist (skip when exhausted: nothing
#     left to spend). This is the bootcount step that drives automatic rollback.
if test "${cera_exhausted}" = "0"; then
  if test "${cera_slot}" = "A"; then setexpr BOOT_A_LEFT ${BOOT_A_LEFT} - 1; fi
  if test "${cera_slot}" = "B"; then setexpr BOOT_B_LEFT ${BOOT_B_LEFT} - 1; fi
  env export -t ${loadaddr} BOOT_ORDER BOOT_A_LEFT BOOT_B_LEFT
  if fatwrite ${devtype} ${devnum}:1 ${loadaddr} boot_state.txt ${filesize}; then
    echo "CeraLive: ${cera_slot} attempts now A=${BOOT_A_LEFT} B=${BOOT_B_LEFT} (persisted)"
  else
    echo "CeraLive: WARNING could not persist boot_state.txt"
  fi
fi

# --- boot the chosen slot. Kernel/DTB/initrd ride INSIDE the rootfs slot's /boot
#     (frozen contract), so load them from the ext4 rootfs partition, not this FAT.
echo "CeraLive: booting slot ${cera_slot} (root=PARTLABEL=${cera_root}, part ${cera_part})"
setenv bootargs "root=PARTLABEL=${cera_root} rootwait rw console=${console} earlycon cera_slot=${cera_slot}"

if test "${fdtfile}" = ""; then
  echo "CeraLive: FATAL fdtfile unset (cera_board.env missing?) — cannot boot"
  exit
fi

ext4load ${devtype} ${devnum}:${cera_part} ${kernel_addr_r} /boot/Image
ext4load ${devtype} ${devnum}:${cera_part} ${fdt_addr_r} /boot/dtb/${fdtfile}
if ext4load ${devtype} ${devnum}:${cera_part} ${ramdisk_addr_r} /boot/initrd.img; then
  booti ${kernel_addr_r} ${ramdisk_addr_r}:${filesize} ${fdt_addr_r}
else
  booti ${kernel_addr_r} - ${fdt_addr_r}
fi
