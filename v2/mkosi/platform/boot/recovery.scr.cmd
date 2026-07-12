# CeraLive manual A/B recovery selector. Load this compiled script from the
# shared FAT partition and set cera_recovery_slot to A or B before `source`.
# shellcheck shell=bash disable=SC2154

if test "${cera_recovery_slot}" = "A"; then
  setenv cera_part 2
  setenv cera_root rootfs_a
elif test "${cera_recovery_slot}" = "B"; then
  setenv cera_part 3
  setenv cera_root rootfs_b
else
  echo "CeraLive recovery: set cera_recovery_slot to A or B"
  exit 1
fi

if test "${fdtfile}" = ""; then
  echo "CeraLive recovery: fdtfile is unset"
  exit 1
fi

setenv bootargs "root=PARTLABEL=${cera_root} rootwait rw console=${console} earlycon cera_slot=${cera_recovery_slot} rauc.slot=${cera_recovery_slot}"
ext4load ${devtype} ${devnum}:${cera_part} ${kernel_addr_r} /boot/Image
ext4load ${devtype} ${devnum}:${cera_part} ${fdt_addr_r} /boot/dtb/rockchip/${fdtfile}
if ext4load ${devtype} ${devnum}:${cera_part} ${ramdisk_addr_r} /boot/initrd.img; then
  booti ${kernel_addr_r} ${ramdisk_addr_r}:${filesize} ${fdt_addr_r}
else
  booti ${kernel_addr_r} - ${fdt_addr_r}
fi
