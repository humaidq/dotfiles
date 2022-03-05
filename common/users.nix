# User and home-manager configurations goes here.
{ config, pkgs, lib, ... }:
{
  imports = [ <home-manager/nixos> ];

  # Define a user account. Don't forget to set a password with ‘passwd’.
  users.users.humaid = {
    isNormalUser = true;
    extraGroups = [ "plugdev" "dialout" ]; # wheel removed since we use doas
    description = "Humaid AlQassimi";
    shell = pkgs.zsh;
  };

  home-manager.users.humaid = {pkgs, lib, ...}: 
  let
    mkTuple = lib.hm.gvariant.mkTuple;
    nur = import (builtins.fetchTarball "https://github.com/nix-community/NUR/archive/master.tar.gz") {
        inherit pkgs;
    };
  in
  {
    nixpkgs.config.allowUnfree = true; # for firefox ext.
    xdg = {
      enable = true;
      mimeApps.enable = true;
      #mime.defaultApplications = {
      #  image/png = [
      #    "img.desktop"
      #  ];

      #};
      userDirs = {
        enable = true;
	createDirectories = false;
	desktop = "$HOME";
	documents = "$HOME/docs";
	download = "$HOME/inbox/web";
	music = "$HOME/docs/music";
	pictures = "$HOME/docs/pics";
	videos = "$HOME/docs/vids";
	publicShare = "";
	templates = "";
      };
    };

    # Manage Firefox
    programs.firefox = {
      enable = true;
      profiles.default = {
        id = 0;
	isDefault = true;
	bookmarks = {
          "nixos.org" = { url = "https://nixos.org"; };
	};
	settings = {
	  # Preferences
	  "browser.newtabpage.enabled" = false; # Blank new page tab
	  "browser.startup.homepage" = "https://start.duckduckgo.com";
          "browser.urlbar.placeholderName" = "DuckDuckGo";
          "browser.search.defaultenginename" = "DuckDuckGo";
	  "signon.rememberSignons" = false; # we use a separate password manager
          "browser.formfill.enable" = false;
	  "findbar.highlightAll" = true;

	  # Only connect to HTTPS websites on all windows
          "dom.security.https_only_mode" = true;
          "dom.security.https_only_mode_ever_enabled" = true;

	  # disable pocket (this seems to not work)
          "extensions.pocket.enable" = false;
	  "browser.pocket.enable" = false;

	  # Disable sponsored results in search bar
	  "browser.urlbar.suggest.quicksuggest.nonsponsored" = false;
	  "browser.urlbar.suggest.quicksuggest.sponsored" = false;

	  # Don't recommend me features or extensions
	  "browser.newtabpage.activity-stream.asrouter.userprefs.cfr.features" = false;
	  "browser.newtabpage.activity-stream.asrouter.userprefs.cfr.addons" = false;

	  # Enable strict tracking protection
	  "privacy.trackingprotection.enabled" = true;
	  "privacy.trackingprotection.fingerprinting.enabled" = true;
	  "privacy.trackingprotection.socialtracking.enabled" = true;
	  "privacy.trackingprotection.pbmode.enabled" = true;
	  "privacy.trackingprotection.cryptomining.enabled" = true;
	 
	  # The rest is from https://github.com/pyllyukko/user.js/blob/master/user.js
	  
          # Disable telemetry, there are way too many settings to do something
	  # this simple...
	  "datareporting.healthreport.uploadEnabled" = false;
	  "datareporting.healthreport.service.enabled" = false;
	  "datareporting.healthreport.dataSubmissionEnabled" = false;
	  "app.normandy.enabled" = false;
	  "toolkit.telemetry.enabled" = false;
	  "toolkit.telemetry.unified" = false;
	  "toolkit.telemetry.archive.enabled" = false;
	  "breakpad.reportURL" = "";
	  "browser.tabs.crashReporting.sendReport" = false;
	  "browser.crashReports.unsubmittedCheck.enabled" = false;
	  # Experiments and stuff
	  "experiments.supported" = false;
	  "experiments.enabled" = false;
	  "extensions.shield-recipe-client.enabled" = false;
	  "app.shield.optoutstudies.enabled" = false;
	  "network.allow-experiments" = false;
	  "browser.discovery.enabled" = false;
	  "security.ssl.errorReporting.automatic" = false;
	  

          # Hardening & anti-fingerprinting stuff
	  # We don't want to set too many "anti-fingerprinting" settings
	  # as that would make our browser unique, which defeats the purpose.
	  "privacy.resistFingerprinting" = true;
	  "privacy.resistFingerprinting.block_mozAddonManager" = true;
	  "browser.fixup.alternate.enabled" = false;
	  "browser.urlbar.trimURLs" = false;
	  "dom.enable_user_timing" = false;
	  "dom.mozTCPSocket.enabled" = false;
	  "dom.network.enabled" = false;
	  "dom.battery.enabled" = false;
	  "beacon.enabled" = false;
	  #"dom.event.clipboardevents.enabled" = false;
	  "device.sensors.enabled" = false;
	  "browser.send_pings" = false;
	  "dom.gamepad.enabled" = false;
	  "browser.search.contryCode" = "US";
	  "browser.search.region" = "US";
	  "browser.search.geoip.url" = "";
	  "intl.accept_languages" = "en";
	  "intl.locale.matchOS" = false;
	  "clipboard.autocopy" = false;
	  "general.buildID.override" = "20100101";
	  "browser.startup.homepage_override.buildID" = "20100101";
	  "browser.uitour.enabled" = false;
	  "network.security.esni.enabled" = true;
	};
      };
      extensions = with nur.repos.rycee.firefox-addons; [
        ublock-origin
        bypass-paywalls-clean
	clearurls
	decentraleyes
	keepassxc-browser
	flagfox
	privacy-badger
	refined-github
	save-page-we
	sponsorblock
	tridactyl
      ];
      package = pkgs.firefox-unwrapped;
      #package = pkgs.wrapFirefox pkgs.firefox-unwrapped {
      #  cfg = {
      #    enableTridactylNative = true;
      #  };

      #  extraPolicies = {
      #    DisablePocket = true;
      #    DisableTelemetry = true;
      #    DisableFirefoxAccounts = true;
      #    DisableFirefoxStudies = true;
      #    DisableFirefoxScreenshots = true;
      #    FirefoxHome = {
      #      Pocket = false;
      #      Snippets = false;
      #    };
      #    UserMessaging = {
      #      ExtensionRecommendations = false;
      #      SkipOnboarding = true;
      #    };
      #    SearchEngines ={
      #      Default = "DuckDuckGo";
      #    };
      #  };
      #};
    };
    programs.tmux = {
      enable = true;
      # This fixes esc delay issue with vim
      escapeTime = 0;
      # Use vi-like keys to move in scroll mode
      keyMode = "vi";
    };
    programs.zsh = {
      enable = true;
      dotDir = ".config/zsh";
      autocd = true;
      enableVteIntegration = true;
      initExtra = ''
        # Load colours and set prompt
        autoload -U colors && colors
        PS1="%B%{$fg[red]%}[%{$fg[yellow]%}%n%{$fg[green]%}@%{$fg[blue]%}%M %{$fg[magenta]%}%~%{$fg[red]%}]%{$reset_color%}$%b "

        source ${pkgs.zsh-autosuggestions}/share/zsh-autosuggestions/zsh-autosuggestions.zsh
      '';
      shellAliases = {
        rebuild = "doas nixos-rebuild switch";
	vim = "nvim";
	vi = "nvim";
      };
      history = {
        size = 10000000;
	#path = "${config.xdg.dataHome}/zsh/history";
      };
      sessionVariables = {
        EDITOR = "nvim";
	LESSHISTFILE = "-";
      };
    };
    dconf.settings = {
      "org/gnome/shell" = {
        favorite-apps = ["firefox.desktop" "mozilla-thunderbird.desktop" "org.gnome.Terminal.desktop"
		"org.gnome.Nautilus.desktop"];
      };
      "org/gnome/desktop/interface" = {
        gtk-theme = "Adwaita-dark";
	clock-format = "12h";
	show-battery-percentage = true;
      };
      "org/gnome/desktop/sound" = {
        allow-volume-above-100-percent = true;
      };
      "org/gnome/desktop/wm/preferences" = { # Add minimise button, use Inter font
        button-layout = "appmenu:minimize,close";
	titlebar-font = "Inter Semi-Bold 11";
      };
      "org/gnome/desktop/input-sources" = { # Add three keyboad layouts (en, ar, fi)
        sources = [(mkTuple ["xkb" "us"] ) ( mkTuple ["xkb" "ara"] ) ( mkTuple["xkb" "fi"])];
	xkb-options = [ "caps:escape" ];
      };
      "org/gnome/desktop/media-handling" = { # Don't mount devices when plugged in
        automount = false;
	automount-open = false;
	autorun-never = true;
      };
      "org/gnome/desktop/interface" = { # Inter font
        document-font-name = "Inter 11";
	font-name = "Inter 11";
      };
    };
    gtk.gtk3.extraConfig = {
      gtk-application-prefer-dark-theme = true;
      gtk-cursor-theme-name = "Adwaita";
    };
    programs.go = {
      enable = true;
      goPath = "repos/go";
    };
    programs.ssh = {
      enable = true;
      matchBlocks."huma.id".user = "root";
    };
    programs.gpg = {
      enable = true;
      #homedir = "${config.home.homeDirectory}/.config/gnupg";
    };
    programs.git = {
      enable = true;
      package = pkgs.gitAndTools.gitFull;
      aliases = { co = "checkout"; };
      #signing.key = "";
      #signing.signByDefault = true;
      delta.enable = true;
      userName = "Humaid AlQassimi";
      userEmail = "git@huma.id";
      extraConfig = {
        core.editor = "nvim";
	pull.rebase = "true";
	init.defaultBranch = "master";
	format.signoff = true;
	url = {
          "git@github.com:".insteadOf = "https://github.com/";
	  "git@git.sr.ht:".insteadOf = "https://git.sr.ht/";
	};
      };
    };
  };
}
