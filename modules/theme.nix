{pkgs, ...}: {
  config = {
    stylix = {
      override = {
        base00 = "#130e24";
        base01 = "#13133a";
        base02 = "#1d2e86";
        base03 = "#134dae";
        base04 = "#3f71c6";
        base05 = "#eeeeee";
        base06 = "#e0e0e0";
        base07 = "#ffffff";
        base08 = "#cc342b";
        base09 = "#f96a38";
        base0A = "#134dae";
        base0B = "#484e50";
        base0C = "#134dae";
        base0D = "#134dae";
        base0E = "#a36ac7";
        base0F = "#134dae";
      };
      image = ./graphics/wallhaven-13mk9v.jpg;
      polarity = "dark";
      targets.plymouth = {
        logo = ../assets/sifr-bios.png;
        logoAnimated = false;
      };
      fonts = {
        sansSerif = {
          package = pkgs.inter;
          name = "Inter";
        };
        monospace = {
          package = pkgs.fira;
          name = "Fira Code";
        };
      };
    };
  };
}
