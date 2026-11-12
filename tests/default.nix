# NixOS VM tests for populate: one test per source type, one for features
# spanning sources, one for edge cases of flakes, one for staying inside the
# target directory, and one for writeDeploy's arguments to nixos-rebuild.  Build all with nix-build tests, or one with,
# e.g., nix-build tests -A flake.  jq runs populate's jq programs for flakes
# without VMs.
{ pkgs ? import ../pkgs {} }:

let
  # HEAD of /fixtures/gitsrc, which fixtures.sh creates deterministically,
  # and its parent.  fixtures.sh fails if HEAD differs, naming the actual one.
  gitHead = "e42d44ef9cdb76ba5a84dff4c89c38222703bf0c";
  gitFirst = "8d47013fa0888948cf0ffcc4e3c69a7b5f180562";

  # rsync versions the scenarios depending on rsync's version run with.
  # callPackage adds override and overrideDerivation, which aren't versions.
  rsyncs = pkgs.lib.filterAttrs
    (_: pkgs.lib.isDerivation)
    (pkgs.callPackage ./rsync.nix {});

  # The scenarios, with populate using rsync.
  scenariosWith = rsync: import ./scenarios.nix {
    inherit (pkgs) lib;
    krops = import ../lib;
    populate = pkgs.populate.override { inherit rsync; };
    inherit (pkgs.krops) writeDeploy;
    url = "http://deployer:8000";
    gitUrl = "git://deployer/gitsrc.git";
    remoteHost = "target";
    agePath = "${pkgs.age}/bin/age";
    inherit gitHead gitFirst;
    rsyncVersion = rsync.version;
  };
  scenarios = scenariosWith pkgs.rsync;
  flakeJq = import ../pkgs/populate/flake-jq.nix;
in
  builtins.mapAttrs
    (name: scenarios: import ./vm.nix { inherit pkgs name scenarios gitHead; })
    scenarios
  // pkgs.lib.mapAttrs'
    (version: rsync: {
      name = "rsync-${builtins.replaceStrings [ "." ] [ "-" ] version}";
      value = import ./vm.nix {
        inherit pkgs gitHead rsync;
        name = "rsync-${version}";
        scenarios = builtins.filter
          (scenario: pkgs.lib.hasInfix "insecureLinks" scenario.name)
          (scenariosWith rsync).file;
      };
    })
    rsyncs
  // {
    # Lock files in the shapes different versions of Nix write.
    jq = pkgs.runCommand "krops-jq" {
      nativeBuildInputs = [ pkgs.jq pkgs.nix ];
    } ''
      sh ${./jq.sh} ${pkgs.linkFarm "krops-flake-jq" (map
        (name: { name = "${name}.jq"; path = pkgs.writeText "${name}.jq" flakeJq.${name}; })
        [ "selected" "selfIsRemote" "selfLocked" ]
        ++ [{
          name = "metadataSubdir.nix";
          path = pkgs.writeText "metadataSubdir.nix" flakeJq.metadataSubdir;
        }])}
      touch $out
    '';
  }
