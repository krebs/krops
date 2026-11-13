# NixOS VM tests for populate: one test per source type, one for features
# spanning sources, one for edge cases of flakes, one for staying inside the
# target directory, and one for writeDeploy's arguments to nixos-rebuild.
# Build all with nix-build tests, or one with, e.g., nix-build tests -A flake.
# The exhaustive tests add the combinations of options that no code path
# tells apart from the ones the others cover; build them with nix-build tests
# -A exhaustive, or one with, e.g., nix-build tests -A exhaustive.flake.
# The smoke test runs a few scenarios covering each source type and each kind
# of target in a single VM test, for checking changes quickly; build it with
# nix-build tests -A smoke.  nix-build tests -A only --argstr only REGEX runs
# the scenarios whose names match the regular expression REGEX in a single
# VM test, e.g. --argstr only 'lock-hooks-.*'.
{ pkgs ? import ../pkgs {}, only ? null }:

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
  scenariosWith = rsync: let
    populate = pkgs.populate.override { inherit rsync; };
  in import ./scenarios.nix {
    inherit (pkgs) lib;
    krops = import ../lib;
    inherit populate;
    inherit (pkgs.krops.override { inherit populate; }) writeDeploy;
    url = "http://deployer:8000";
    gitUrl = "git://deployer/gitsrc.git";
    remoteHost = "target";
    agePath = "${pkgs.age}/bin/age";
    inherit gitHead gitFirst;
    rsyncVersion = rsync.version;
  };
  scenarios = scenariosWith pkgs.rsync;
  # VM tests of those of the groups of scenarios that are, or aren't,
  # exhaustive, named after the groups with prefix in front.
  testsOf = exhaustive: prefix: pkgs.lib.mapAttrs
    (name: scenarios: import ./vm.nix {
      inherit pkgs gitHead scenarios;
      name = prefix + name;
    })
    (pkgs.lib.filterAttrs (_: scenarios: scenarios != [])
      (builtins.mapAttrs
        (_: builtins.filter (scenario: scenario.exhaustive == exhaustive))
        scenarios));

  # Names of the scenarios of the smoke test.
  smokeNames = [
    "file-local-checksum0-deleteExcluded0-filters0-inputsnone"
    "file-sudo-checksum0-deleteExcluded0-filters1-inputsnone"
    "git-remote-cleanExclude0-fetchAlways0-inputsnone-shallow0"
    "git-local-shallow1-refs"
    "symlink-local-absolute0-inputs0"
    "pass-remote-storepass"
    "passage-sudo-agedefault-dirstore"
    "pipe-local"
    "derivation-remote"
    "flake-local-fetchOnTarget0-inputsrewrite-kindgit-materialize0"
    "flake-sudo-fetchOnTarget1-inputsnone-kindgit-materialize0"
    "flake-input-dep-remote-fetchOnTarget0-inputsgenerated-materialize0"
    "flake-input-sub-local-fetchOnTarget0-materialize0"
    "state-sentinel-local"
    "prune-remote"
    "names-local"
    "paths-local"
    "deploy-local-buildTarget0-etcFlake0-flakefile"
    "deploy-sudo-allocateTTY"
  ];
  allScenarios = pkgs.lib.concatLists (builtins.attrValues scenarios);
  smokeScenarios = let
    selected = builtins.filter (scenario: builtins.elem scenario.name smokeNames) allScenarios;
    missing = pkgs.lib.subtractLists (map (scenario: scenario.name) selected) smokeNames;
  in
    if missing != [] then
      throw "tests: smoke test names missing scenarios: ${toString missing}"
    else
      selected;
  # The scenarios whose names match the regular expression only.
  onlyScenarios = let
    selected = builtins.filter
      (scenario: builtins.match only scenario.name != null)
      allScenarios;
  in
    if only == null then
      throw "tests: -A only needs --argstr only REGEX"
    else if selected == [] then
      throw "tests: no scenario's name matches ${builtins.toJSON only}"
    else
      selected;
in
  testsOf false ""
  # Not built by nix-build tests either, which runs these scenarios anyway.
  // {
    smoke.smoke = import ./vm.nix {
      inherit pkgs gitHead;
      name = "smoke";
      scenarios = smokeScenarios;
    };
    only.only = import ./vm.nix {
      inherit pkgs gitHead;
      name = "only";
      scenarios = onlyScenarios;
    };
  }
  # An attribute set without recurseForDerivations, so nix-build tests
  # doesn't build them.
  // { exhaustive = testsOf true "exhaustive-"; }
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
