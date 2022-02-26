# This is the commons files, which is attributes that spans different
# system types (e.g. graphical, server, RPi, etc).
{ config, pkgs, lib, ... }:
{

  imports =
    [
      ./users.nix
      ./security.nix
      ./apps.nix
      ./graphical.nix
    ];
  time.timeZone = "Asia/Dubai";

  documentation = {
    enable = true;
    nixos.enable = true;
    man.enable = true;
    man.generateCaches = true;
    info.enable = true;
    doc.enable = true;
  };

  # Some programs need SUID wrappers, can be configured further or are
  # started in user sessions.
  programs = {
    mtr.enable = true;
    gnupg.agent = {
      enable = true;
      enableSSHSupport = true;
    };
  };
  services.fwupd.enable = true;

  nixpkgs.config.allowUnfree = true;
  nix.allowedUsers = [ "humaid" ];

    sound.enable = true;
  nixpkgs.overlays = [
     (self: super: {
      tor-browser-bundle-bin = super.tor-browser-bundle-bin.overrideAttrs (old: rec  {
        src = super.fetchurl {
          url = "https://huma.id/tor-browser-linux64-11.0.6_en-US.tar.xz";
          sha256 = "dfb1d238e2bf19002f2f141178c3af80775dd8d5d83b53b0ab86910ec4a1830d";
        };
      });
     })
   ];
  # List packages installed in system profile. To search, run:
  # $ nix search wget
  environment.systemPackages = with pkgs; [
    zsh
    zsh-autosuggestions
    neovim
    wget
    tmux
    ranger
    htop
    wget
    curl
    tcpdump
    file
    lsof
    strace
    xz
    zip
    lz4
    unzip
    rsync
    tree
    pwgen
    jq
    ripgrep
    ripgrep-all
    usbutils
    pciutils
    gitAndTools.gitFull
    xclip
    killall
    file
    du-dust
    wike
  #];
    firefox
    tor-browser-bundle-bin
    gimp
    keepassxc

    signal-desktop
    libreoffice
    vlc
    obs-studio

    # Productivity
    prusa-slicer
    audacity
    gimp
    inkscape
    audacity
    gimp
    inkscape
    libreoffice
    vlc
    obs-studio


    # CLI productivity
    jpegoptim
    optipng
    languagetool
    aspell
    aspellDicts.ar
    aspellDicts.en
    aspellDicts.fi

    # CLI productivity
    jpegoptim
    optipng
    languagetool
  ];
  programs.neovim.viAlias = true;
  programs.neovim.vimAlias = true;

  hardware.pulseaudio.enable = false;
  hardware.cpu.intel.updateMicrocode = true;

}

