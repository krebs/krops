# writeDeploy of krops' flake, with the arguments args, given krops' and
# nixpkgs' sources: what the flake ./pure.nix makes evaluates purely, and
# what the host builds.  nixpkgs is a flake with lib and legacyPackages,
# without nixpkgs' configuration and overlays, which differ between the
# two, and which pure evaluation can't read anyway.
{ krops, nixpkgs, system, args }:

let
  nixpkgs' = {
    lib = import "${nixpkgs}/lib";
    legacyPackages.${system} = import nixpkgs {
      inherit system;
      config = {};
      overlays = [];
    };
  };
  kropsFlake = (import "${krops}/flake.nix").outputs {
    self = kropsFlake;
    nixpkgs = nixpkgs';
  };
in
  kropsFlake.lib.${system}.writeDeploy "deploy" args
