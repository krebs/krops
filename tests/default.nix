# NixOS VM tests for populate: one test per source type, one for features
# spanning sources, one for edge cases of flakes, and one for writeDeploy's
# arguments to nixos-rebuild.  Build all with nix-build tests, or one with,
# e.g., nix-build tests -A flake.  jq runs populate's jq programs for flakes
# without VMs.
{ pkgs ? import ../pkgs {} }:

let
  # HEAD of /fixtures/gitsrc, which fixtures.sh creates deterministically,
  # and its parent.  fixtures.sh fails if HEAD differs, naming the actual one.
  gitHead = "e42d44ef9cdb76ba5a84dff4c89c38222703bf0c";
  gitFirst = "8d47013fa0888948cf0ffcc4e3c69a7b5f180562";

  scenarios = import ./scenarios.nix {
    inherit (pkgs) lib;
    krops = import ../lib;
    inherit (pkgs) populate;
    inherit (pkgs.krops) writeDeploy;
    url = "http://deployer:8000";
    gitUrl = "git://deployer/gitsrc.git";
    remoteHost = "target";
    agePath = "${pkgs.age}/bin/age";
    inherit gitHead gitFirst;
    rsyncVersion = pkgs.rsync.version;
  };
  flakeJq = import ../pkgs/populate/flake-jq.nix;
in
  builtins.mapAttrs
    (name: scenarios: import ./vm.nix { inherit pkgs name scenarios gitHead; })
    scenarios
  // {
    # Lock files in the shapes different versions of Nix write.
    jq = pkgs.runCommand "krops-jq" { nativeBuildInputs = [ pkgs.jq ]; } ''
      sh ${./jq.sh} ${pkgs.linkFarm "krops-flake-jq" (map
        (name: { name = "${name}.jq"; path = pkgs.writeText "${name}.jq" flakeJq.${name}; })
        [ "selected" "selfIsRemote" "selfLocked" ])}
      touch $out
    '';
  }
