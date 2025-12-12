{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.sifr.graphics.labwc;
  screen = pkgs.callPackage ../screenshot.nix { };

  autostart = ''
    systemctl --user import-environment WAYLAND_DISPLAY
    dbus-update-activation-environment --systemd DISPLAY WAYLAND_DISPLAY XDG_CURRENT_DESKTOP
    sleep 0.3 # make sure variables are set
    ${pkgs.sfwbar}/bin/sfwbar &
    ${pkgs.swaybg}/bin/swaybg -m fill -i ${../wallhaven-13mk9v.jpg} &
  '';

  environment = ''
    GDK_SCALE=2
    XCURSOR_THEME=Adwaita
    XCURSOR_SIZE=24
  '';

  rcXml = ''
    <?xml version="1.0"?>
    <labwc_config>
    <core><gap>5</gap></core>
    <theme>
      <name>sifr</name>
      <dropShadows>yes</dropShadows>
      <titlebar>
        <layout>icon:iconify,max,close</layout>
      </titlebar>
      <font place="">
        <name>Fira Sans</name>
        <size>12</size>
        <slant>normal</slant>
        <weight>bold</weight>
      </font>
      <font place="ActiveWindow">
        <name>Fira Sans</name>
        <size>12</size>
        <slant>normal</slant>
        <weight>bold</weight>
      </font>
    </theme>
    <snapping>
      <overlay>
        <enabled>true</enabled>
        <delay inner="500" outer="500"/>
      </overlay>
    </snapping>
    <placement>
      <policy>cascade</policy>
      <cascadeOffset x="40" y="30" />
    </placement>
    <desktops number="4">
      <popupTime>0</popupTime>
      <prefix>Desktop</prefix>
    </desktops>
    <keyboard>
      <default />
      <keybind key="W-l">
        <action name="Execute" command="${pkgs.systemd}/bin/loginctl lock-session" />
      </keybind>
      <keybind key="Print">
        <action name="Execute" command="${screen}/bin/screen" />
      </keybind>
      <keybind key="XF86_Display">
        <action name="Execute" command="${lib.getExe pkgs.wdisplays}" />
      </keybind>
      <keybind key="XF86_MonBrightnessUp">
        <action name="Execute" command="brightnessctl set 5%+" />
      </keybind>
      <keybind key="XF86_MonBrightnessDown">
        <action name="Execute" command="brightnessctl set 5%-" />
      </keybind>
      <keybind key="XF86_AudioRaiseVolume">
        <action name="Execute" command="amixer set Master 5%+" />
      </keybind>
      <keybind key="XF86_AudioLowerVolume">
        <action name="Execute" command="amixer set Master 5%-" />
      </keybind>
      <keybind key="XF86_AudioMute">
        <action name="Execute" command="amixer set Master toggle" />
      </keybind>
      <keybind key="XF86_MicMute">
        <action name="Execute" command="amixer set Capture toggle" />
      </keybind>
      <keybind key="W-z">
        <action name="ToggleMagnify" />
      </keybind>
      <keybind key="W--">
        <action name="ZoomOut" />
      </keybind>
      <keybind key="W-=">
        <action name="ZoomIn" />
      </keybind>
    </keyboard>
    <mouse>
      <default />
      <context name="Root">
        <mousebind button="Left" action="Press" />
        <mousebind button="Middle" action="Press" />
        <mousebind button="Right" action="Press" />
        <!--Disable default scrolling behavior of switching workspaces-->
        <mousebind direction="Up" action="Scroll" />
        <mousebind direction="Down" action="Scroll" />
      </context>
    </mouse>
    <libinput>
      <device category="touchpad"><naturalScroll>yes</naturalScroll></device>
    </libinput>
    <windowSwitcher show="yes" preview="yes" outlines="yes" allWorkspaces="yes">
      <fields>
        <field content="title"  width="75%" />
        <field content="output"  width="25%" />
      </fields>
    </windowSwitcher>
    </labwc_config>
  '';

in
{
  imports = [
    ../wayland-services.nix
  ];

  options.sifr.graphics = {
    labwc.enable = lib.mkEnableOption "desktop environment with labwc";
  };

  config = lib.mkIf cfg.enable {
    programs.xwayland.enable = true;
    programs.labwc.enable = true;

    environment.systemPackages = with pkgs; [ sfwbar ];
    environment.etc = {
      "xdg/labwc/rc.xml".text = rcXml;
      "xdg/labwc/autostart" = {
        text = autostart;
        mode = "0755";
      };
      #"labwc/menu.xml".text = menuXml;
      "xdg/labwc/environment".text = environment;
    };
  };
}
