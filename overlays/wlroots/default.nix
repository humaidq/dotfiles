{ prev, ... }:
prev.wlroots.overrideAttrs (old: {
  patches = (old.patches or [ ]) ++ [
    (prev.fetchpatch {
      # From https://github.com/swaywm/sway/issues/8194#issuecomment-3303741489
      url = "https://github.com/user-attachments/files/22390209/wlroots-surface-alloc-fix.patch";
      hash = "sha256-VIqNGYGge10/S/Q1Nw+jihdBkWNKdau0S4MFstiqm6o=";
    })
  ];
})
