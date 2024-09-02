{
  pkgs,
  vars,
  inputs,
  lib,
  self,
  ...
}:
{
  imports = [
    self.nixosModules.sifrOS
    "${inputs.nixos-hardware-star64}/pine64/star64/sd-image.nix"
  ];
  networking.hostName = "boerbok";

  sifr = {
    security.harden = false;
    # LuaJIT not available for riscv64
    applications.neovim.enable = false;
    profiles.base = true;
    profiles.basePlus = true;
  };

  hardware.deviceTree.overlays = [
    {
      name = "8GB-patch";
      dtsFile = "${inputs.nixos-hardware-star64}/pine64/star64/star64-8GB.dts";
    }
  ];

  system.stateVersion = "24.05";
  nixpkgs.hostPlatform = "riscv64-linux";

  networking.networkmanager.enable = false;

  networking.useDHCP = true;
  services.openssh.enable = true;

  users.users.${vars.user} = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    hashedPassword = "$6$67sQfb8Pm3Jyvdvo$OPXnLbgHCdoRfhlhhz/pygvJ32ZA.L0HifV.fBSVW47SsfKK6xiroi/Xx.hcB6YJ94XXaiUH5zqDvnAmKq6gE1";
    hashedPasswordFile = lib.mkForce null;
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPx68Wz04/MkfKaptXlvghLjwnW3sTUXgZgiDD3Nytii humaid@goral"
    ];
  };

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  time.timeZone = "Asia/Dubai";

  environment.systemPackages = with pkgs; [
    git
    vim
    htop
    tmux
  ];

  system.extraDependencies =
    with pkgs;
    # Include only in native builds.
    # Use normalized platforms from stdenv.
    lib.optionals (stdenv.buildPlatform == stdenv.hostPlatform) (
      builtins.concatMap (x: x.all) [
        autoconf
        automake
        bash
        binutils
        bison
        busybox
        cargo
        clang
        cmake
        config.boot.kernelPackages.kernel
        curl
        dtc
        elfutils
        flex
        gcc
        gitMinimal
        glibc
        glibcLocales
        jq
        llvm
        meson
        ninja
        openssl
        pkg-config
        python3
        rustc
        stdenv
        # Bootstrap stages. Yes, this is the right way to do it.
        stdenv.__bootPackages.stdenv
        stdenv.__bootPackages.stdenv.__bootPackages.stdenv
        stdenv.__bootPackages.stdenv.__bootPackages.stdenv.__bootPackages.stdenv
        stdenv.__bootPackages.stdenv.__bootPackages.stdenv.__bootPackages.stdenv.__bootPackages.stdenv
        stdenv.__bootPackages.stdenv.__bootPackages.stdenv.__bootPackages.stdenv.__bootPackages.stdenv.__bootPackages.stdenv
        stdenv.__bootPackages.stdenv.__bootPackages.stdenv.__bootPackages.stdenv.__bootPackages.stdenv.__bootPackages.stdenv.__bootPackages.stdenv
        stdenv.__bootPackages.stdenv.__bootPackages.stdenv.__bootPackages.stdenv.__bootPackages.stdenv.__bootPackages.stdenv.__bootPackages.stdenv.__bootPackages.stdenv
        stdenv.cc
        stdenv.__bootPackages.stdenv.cc
        stdenv.__bootPackages.stdenv.__bootPackages.stdenv.cc
        stdenv.__bootPackages.stdenv.__bootPackages.stdenv.__bootPackages.stdenv.cc
        stdenv.__bootPackages.stdenv.__bootPackages.stdenv.__bootPackages.stdenv.__bootPackages.stdenv.cc
        stdenv.__bootPackages.stdenv.__bootPackages.stdenv.__bootPackages.stdenv.__bootPackages.stdenv.__bootPackages.stdenv.cc
        stdenv.__bootPackages.stdenv.__bootPackages.stdenv.__bootPackages.stdenv.__bootPackages.stdenv.__bootPackages.stdenv.__bootPackages.stdenv.cc
        stdenvNoCC
        unzip
        util-linux
        zip
        zlib
      ]
    );
}
