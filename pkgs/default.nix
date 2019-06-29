{ overlays ? [], ... }@args:

let
  nix-writers = builtins.fetchGit {
    url = https://cgit.krebsco.de/nix-writers/;
    rev = "c528cf970e292790b414b4c1c8c8e9d7e73b2a71";
  };
in

import <nixpkgs> (args // {
  overlays = [
    (import ./overlay.nix)
    (import "${nix-writers}/pkgs")
  ] ++ overlays;
})
