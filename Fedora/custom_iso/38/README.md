#### Creating custom iso for usb/dvd from stock Fedora iso using mkksiso

mkksiso --ks ./fedora38_cinn_iso.ks ./Fedora-Everything-netinst-x86_64-38-1.6.iso ./fedora-38-cinn-dual-ks-20231112.iso

#### Creating custom iso using xorriso
Note: due to embedded EFI image in new grub-only iso format in Fedora 37 onwards, using just xorriso won't change the boot menu when booting from a usb stick
TODO: show manual process for updating embedded EFI image. See https://github.com/weldr/lorax/pull/1290 https://github.com/weldr/lorax/pull/1226/commits/d0467b4356d9b797be48df5dd96f7c81b83c4b63

xorriso -indev Fedora-Everything-netinst-x86_64-38-1.6.iso -outdev Fedora-38-cinn-dual-ks.iso -compliance no_emul_toc -overwrite nondir -map ./fedora38_cinn_iso.ks "/ks.cfg" -map ./BOOT.conf "/EFI/BOOT/BOOT.conf" -map ./BOOT.conf "/EFI/BOOT/grub.cfg" -map ./BOOT.conf "/boot/grub2/grub.cfg" -boot_image any replay
