{ pkgs, lib, ... }:
let
  desktopEntry = name: command: {
    executable = true;
    text = ''
      [Desktop Entry]
      Type=Application
      Name=${name}
      Exec=${command}
    '';
  };
in
{
  xdg = {
    enable = true;
    mimeApps.enable = true;
    #portal = {
    #  enable = true;
    #  extraPortals = with pkgs; [
    #    xdg-desktop-portal-wlr
    #    xdg-desktop-portal-gtk
    #  ];
    #  gtkUsePortal = true;
    #};
    mimeApps.defaultApplications = {
      "inode/directory" = [ "file.desktop" ];

      # Images
      "image/png" = [ "img.desktop" ];
      "image/jpeg" = [ "img.desktop" ];
      "image/gif" = [ "img.desktop" ];

      # Text
      "text/x-shellscript" = [ "text.desktop" ];
      "text/x-c" = [ "text.desktop" ];
      "text/x-lisp" = [ "text.desktop" ];
      "text/html" = [ "text.desktop" ];
      "text/plain" = [ "text.desktop" ];

      # PDF
      "application/pdf" = [ "pdf.desktop" ];
      "application/postscript" = [ "pdf.desktop" ];

      # Videos
      "video/mp4" = [ "video.desktop" ];
      "video/x-msvideo" = [ "video.desktop" ];
      "video/quicktime" = [ "video.desktop" ];
    };
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
    configFile."user-dirs.locale".text = "en_GB";

    # prevent home-manager from failing after rebuild
    configFile."mimeapps.list".force = true;

    # Desktop entry aliases
    dataFile."applications/img.desktop" =
      desktopEntry "Image Viewer" "${pkgs.sxiv}/bin/sxiv -a %f";

    dataFile."applications/file.desktop" =
      desktopEntry "File Manager" "${pkgs.st}/bin/st -e lf %u";

    dataFile."applications/text.desktop" =
      desktopEntry "Text Editor" "${pkgs.emacs}/bin/emacs %f";

    dataFile."applications/pdf.desktop" =
      desktopEntry "PDF Viewer" "${pkgs.zathura}/bin/zathura %u";

    dataFile."applications/video.desktop" =
      desktopEntry "Video Player" "${pkgs.vlc}/bin/vlc %u";
  };

}
