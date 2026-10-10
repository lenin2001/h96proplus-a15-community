# H96 Pro Plus (S912) SD rescue autoscript — public version (derived from the maintainer's rev 4)
#
# The vendor U-Boot of this board runs aml_autoscript from an inserted SD card on its
# update/recovery path (update -> recovery_from_sdcard). On a stock unit that path is
# usually entered by holding the reset button inside the AV jack while applying power;
# verify the method on your own unit.
#
# Card states:
#   ARMED     aml_autoscript + RESCUE.TAG + rescue.img + dtb.img -> boots the rescue
#   DISARMED  aml_autoscript renamed to aml_autoscript.off       -> the loader ignores the card
# Without RESCUE.TAG this script boots nothing and the vendor loader continues as usual.
#
# Nothing here writes the U-Boot environment or the eMMC. The maintainer's rev 4 also had an
# emergency "Android from SD" fallback with an unpublished kernel; it is removed here.
# Comments and blank lines are stripped before mkimage (rescue/sd/build-autoscript.sh).
echo "== H96 SD rescue autoscript (public) =="
mmcinfo
if fatload mmc 0 0x20000000 RESCUE.TAG; then
  echo "-- RESCUE.TAG: booting rescue.img"
  setenv bootargs "console=ttyAML0,115200 rescue=1"
  if fatload mmc 0 0x08000000 rescue.img; then
    if fatload mmc 0 ${dtb_mem_addr} dtb.img; then
      bootm 0x08000000
    fi
  fi
  echo "-- rescue.img or dtb.img could not be loaded/booted"
fi
echo "-- no rescue boot: the vendor loader continues (disarm or remove the card to boot the eMMC)"
