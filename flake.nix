{
  description = "krops - krebs operations";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs, ... }:
    let
      supportedSystems = [
        "x86_64-linux"
        "i686-linux"
        "aarch64-linux"
        "riscv64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
    in
    {
      lib = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          krops = pkgs.callPackage ./pkgs/krops {};
          populate = pkgs.callPackage ./pkgs/populate {};
        in {
          inherit populate;
          inherit (krops) rebuild runShell withNixOutputMonitor writeCommand writeDeploy writeTest;
        });
    };
}
