{nixpkgs}:{
  imports = ["${nixpkgs}/nixos/modules/installer/cd-dvd/iso-image.nix"];
  formatAttr = "isoImage";
  fileExtension = ".iso";
  system.nixos.distroName = "hsys";
  system.nixos.distroId = "hsys";
  isoImage = {
    isoBaseName = "hsys";
    #compressImage = true;
    squashfsCompression = "zstd -Xcompression-level 6";
    efiSplashImage = ../common/assets/hsys-lightdm.png;
    splashImage = ../common/assets/hsys-bios.png; # BIOS boot
    #grubTheme = null;

    # Make EFI & USB bootable
    makeEfiBootable = true;
    makeUsbBootable = true;
  };
}
