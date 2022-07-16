{ nixosConfig, config, pkgs, lib, ... }:
let
  graphical = nixosConfig.hsys.enableGnome || nixosConfig.hsys.enableDwm;
in
{
  config = lib.mkMerge [
    (lib.mkIf graphical {
      qt = {
        enable = true;
        platformTheme = "gtk";
        style.package = pkgs.adwaita-qt;
        style.name = "adwaita-dark";
      };

      gtk = {
        enable = true;
        theme.name = "Adwaita-dark";
        gtk3.extraConfig = {
          gtk-application-prefer-dark-theme = true;
          gtk-cursor-theme-name = "Adwaita";
        };
        gtk3.bookmarks = [
          "file:///home/humaid/docs"
          "file:///home/humaid/repos"
          "file:///home/humaid/inbox"
          "file:///home/humaid/inbox/web"
        ];
      };

      #  xdg.configFile."vlc/vlcrc".text = ''
      #[qt]
      ## Do not ask for network policy at start
      #qt-privacy-ask=0
      #'';

      xsession.enable = true;
      xsession.profileExtra = "export PATH=$PATH:$HOME/.bin";
      services.dunst = {
        enable = true;
        #iconTheme.package = pkgs.gnome.adwaita-icon-theme;
        settings = {
          global = {
            frame_color = "#1d2e86";
          };
          urgency_normal = {
            background = "#130e24";
            foreground = "#ffffff";
            timeout = 8;
          };
        };
      };

    })
  ];
}
