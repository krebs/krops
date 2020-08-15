{
  description = "Krops: Lightweight NixOS deployment toolkit";

  inputs.flake-utils.url = "github:numtide/flake-utils";

  outputs = { self, nixpkgs, flake-utils }: {
    lib = import ./lib {
      nixpkgsLib = nixpkgs.lib;
    };
  } // (flake-utils.lib.eachSystem flake-utils.lib.allSystems (system:
    let
      pkgs = nixpkgs.legacyPackages.${system};
      populate = pkgs.callPackage ./pkgs/populate {
        inherit (self) lib;
      };
    in {
      packages = (pkgs.callPackage ./pkgs/krops {
        inherit (self) lib;
        inherit populate;
      });
    }
  ));
}
