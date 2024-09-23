{ prev }:
prev.liquidctl.overrideAttrs {
  src = prev.fetchFromGitHub {
    owner = "liquidctl";
    repo = "liquidctl";
    rev = "3cc1f25a26db9949f072949b048da986bcc1c263";
    hash = "sha256-cWTHeYlvKE+twrJKy6+2tiPnIiVqNUMoK0UTLWeMnb0=";
  };
  patches = [ ];
}
