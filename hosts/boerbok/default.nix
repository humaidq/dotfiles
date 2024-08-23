{
  pkgs,
  vars,
  inputs,
  lib,
  ...
}:
{
  imports = [
    #self.nixosModules.sifrOS
    "${inputs.nixos-hardware}/pine64/star64/sd-image.nix"
  ];
  networking.hostName = "boerbok";

  #sifr = {
  #  security.harden = false;
  #  tailscale = {
  #    enable = false;
  #    exitNode = true;
  #    ssh = true;
  #  };
  #  profiles.base = false;
  #};

  hardware.deviceTree.overlays = [
    {
      name = "8GB-patch";
      dtsFile = "${inputs.nixos-hardware}/pine64/star64/star64-8GB.dts";
    }
  ];

  system.stateVersion = "24.05";
  nixpkgs.hostPlatform = "riscv64-linux";
  nixpkgs.buildPlatform = "x86_64-linux";

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

  environment.systemPackages = with pkgs; [
    git
    vim
    htop
    tmux
  ];

  # Provide a bunch of build dependencies to minimize rebuilds.
  # Alternatively, sdImage.storePaths will not tie the packages to the system, allowing GC.
  # system.includeBuildDependencies is another alternative, but results in a WAY bigger image.
  #  system.extraDependencies =
  #    # Include only in native builds.
  #    # Use normalized platforms from stdenv.
  #    lib.optionals (pkgs.stdenv.buildPlatform == pkgs.stdenv.hostPlatform) (
  #      with pkgs;
  #      builtins.concatMap (x: x.all) [
  #        autoconf
  #        automake
  #        bash
  #        binutils
  #        bison
  #        busybox
  #        cargo
  #        clang
  #        cmake
  #        curl
  #        dtc
  #        elfutils
  #        flex
  #        gcc
  #        gitMinimal
  #        glibc
  #        glibcLocales
  #        jq
  #        llvm
  #        meson
  #        ninja
  #        openssl
  #        pkg-config
  #        python3
  #        rustc
  #        stdenv
  #        # Bootstrap stages. Yes, this is the right way to do it.
  #        stdenv.__bootPackages.stdenv
  #        stdenv.__bootPackages.stdenv.__bootPackages.stdenv
  #        stdenv.__bootPackages.stdenv.__bootPackages.stdenv.__bootPackages.stdenv
  #        stdenv.__bootPackages.stdenv.__bootPackages.stdenv.__bootPackages.stdenv.__bootPackages.stdenv
  #        stdenv.__bootPackages.stdenv.__bootPackages.stdenv.__bootPackages.stdenv.__bootPackages.stdenv.__bootPackages.stdenv
  #        stdenv.__bootPackages.stdenv.__bootPackages.stdenv.__bootPackages.stdenv.__bootPackages.stdenv.__bootPackages.stdenv.__bootPackages.stdenv
  #        stdenv.__bootPackages.stdenv.__bootPackages.stdenv.__bootPackages.stdenv.__bootPackages.stdenv.__bootPackages.stdenv.__bootPackages.stdenv.__bootPackages.stdenv
  #        stdenv.cc
  #        stdenv.__bootPackages.stdenv.cc
  #        stdenv.__bootPackages.stdenv.__bootPackages.stdenv.cc
  #        stdenv.__bootPackages.stdenv.__bootPackages.stdenv.__bootPackages.stdenv.cc
  #        stdenv.__bootPackages.stdenv.__bootPackages.stdenv.__bootPackages.stdenv.__bootPackages.stdenv.cc
  #        stdenv.__bootPackages.stdenv.__bootPackages.stdenv.__bootPackages.stdenv.__bootPackages.stdenv.__bootPackages.stdenv.cc
  #        stdenv.__bootPackages.stdenv.__bootPackages.stdenv.__bootPackages.stdenv.__bootPackages.stdenv.__bootPackages.stdenv.__bootPackages.stdenv.cc
  #        stdenvNoCC
  #        unzip
  #        util-linux
  #        zip
  #        zlib
  #      ]
  #    );
}
