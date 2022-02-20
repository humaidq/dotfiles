# This contains settings to provide a graphical system.
{ config, pkgs, ... }:

{
  imports =
    [ # Include the results of the hardware scan.
      ./common.nix
    ];

  services = {
    # Configure keymap in X11 (outdated - we use wayland now)
    xserver = {
      enable = true;
      desktopManager.gnome.enable = true;
      desktopManager.xterm.enable = false;
      displayManager.gdm.enable = true;
      layout = "us,ar";
      xkbOptions = "caps:escape";
      libinput.enable = false;
      synaptics.enable = true;
      synaptics.twoFingerScroll = true;
    };

    # Yubikey
    udev.packages = with pkgs; [ libu2f-host yubikey-personalization ];
    pcscd.enable = true;
 
    printing.enable = true;
    pipewire = {
      enable = true;
      alsa.enable = true;
      alsa.support32Bit = true;
      pulse.enable = true;
    };
 
    flatpak.enable = true;
  };


  environment.gnome.excludePackages = [
    pkgs.gnome.geary
    pkgs.gnome.gnome-music
    pkgs.epiphany
  ];
  # Enable the GNOME Desktop Environment.
 
  # Enable sound.
  sound.enable = true;
  security = {
    rtkit.enable = true;
    doas = {
      enable = true;
      extraRules = [{
        users = [ "humaid" ];
        persist = true;
	keepEnv = true;
      }];
    };
    sudo.enable = false;
    protectKernelImage = true;

  };


  # List packages installed in system profile. To search, run:
  # $ nix search wget
  environment.systemPackages = with pkgs; [
    zsh
    zsh-autosuggestions
    neovim
    wget
    tmux
    firefox
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
    usbutils
    pciutils
    gitAndTools.gitFull
    xclip


    killall
    file
    gimp
    du-dust
    mdbook
    hugo
    keepassxc
    google-fonts

    gnome.dconf-editor

    # Programming
    gnupg
    gdb
    bvi
    plantuml
    bc
    gnumake
    bat
    ffmpeg
    lm_sensors
    minify

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

    # Desktop
    signal-desktop
    libreoffice
    vlc
    obs-studio

    # CLI productivity
    jpegoptim
    optipng
    languagetool

    # Desktop
    signal-desktop


  ];
  programs.neovim.viAlias = true;
  programs.neovim.vimAlias = true;

  hardware.pulseaudio.enable = false;
  hardware.cpu.intel.updateMicrocode = true;
}

