{ overlays ? [], ... }@args:

import <nixpkgs> (args // {
  overlays = overlays ++ [
    (import ./overlay.nix)
  ];
})
