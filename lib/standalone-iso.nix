{nixpkgs}: {
  imports = ["${nixpkgs}/nixos/modules/installer/cd-dvd/iso-image.nix"];
  formatAttr = "isoImage";
  fileExtension = ".iso";
  system.nixos.distroName = "sifr";
  system.nixos.distroId = "sifr";
  isoImage = {
    isoBaseName = "sifr";
    #compressImage = true;
    squashfsCompression = "zstd -Xcompression-level 6";
    efiSplashImage = ../assets/sifr-lightdm.png;
    splashImage = ../assets/sifr-bios.png; # BIOS boot
    #grubTheme = null;

    # Make EFI & USB bootable
    makeEfiBootable = true;
    makeUsbBootable = true;
  };
}
