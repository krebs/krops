# NixOS VM tests for populate: one test per source type, one for features
# spanning sources, one for edge cases of flakes, and one for writeDeploy's
# arguments to nixos-rebuild.  Build all with nix-build tests, or one with,
# e.g., nix-build tests -A flake.
{ pkgs ? import ../pkgs {} }:

let
  # HEAD of /fixtures/gitsrc, which fixtures.sh creates deterministically.
  # fixtures.sh fails if it differs, naming the actual one.
  gitHead = "e42d44ef9cdb76ba5a84dff4c89c38222703bf0c";

  scenarios = import ./scenarios.nix {
    inherit (pkgs) lib;
    krops = import ../lib;
    inherit (pkgs) populate;
    inherit (pkgs.krops) writeDeploy;
    url = "http://deployer:8000";
    gitUrl = "git://deployer/gitsrc.git";
    remoteHost = "target";
    agePath = "${pkgs.age}/bin/age";
    inherit gitHead;
  };
in
  builtins.mapAttrs
    (name: scenarios: import ./vm.nix { inherit pkgs name scenarios gitHead; })
    scenarios
