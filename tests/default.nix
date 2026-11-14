# NixOS VM tests for krops, with the VM machinery and the scenarios of
# populate's tests, in ../pkgs/populate/tests: deploy, for writeDeploy's
# arguments to nixos-rebuild, and populate, for pkgs.populate, running
# populate's scenarios that expect populate to refuse its arguments, which
# pkgs.populate does during evaluation here, and the scenarios of
# populate's smoke test, with target attribute sets as mkTarget returns
# them.  Build all with nix-build tests, or one with, e.g., nix-build tests
# -A deploy.  The exhaustive tests add the combinations of options that no
# code path tells apart from the ones the others cover; build them with
# nix-build tests -A exhaustive.  The smoke test runs a few scenarios of
# each in a single VM test; build it with nix-build tests -A smoke.
# nix-build tests -A only --argstr only REGEX runs the scenarios whose
# names match the regular expression REGEX, of all of populate's scenarios
# and krops' own, in a single VM test, e.g. --argstr only 'lock-hooks-.*'.
# populate's own tests run the program directly; see
# ../pkgs/populate/README.md.
{ pkgs ? import ../pkgs {}, only ? null }:

let
  inherit (pkgs) lib;
  krops = import ../lib;
  populateTests = ../pkgs/populate/tests;

  inherit (import (populateTests + "/fixtures.nix")) gitHead gitFirst;

  remoteHost = "target";

  # Targets of each kind for a path, as mkTarget returns them.
  targets = {
    local = path: krops.mkTarget "" // { host = "localhost"; inherit path; };
    remote = path: {
      user = "root"; host = remoteHost; port = null; inherit path;
      sudo = false; extraOptions = [];
    };
    sudo = path: {
      user = "deploy"; host = remoteHost; port = null; inherit path;
      sudo = true; extraOptions = [];
    };
  };

  # A phase runs pkgs.populate, or writeDeploy with a stand-in for
  # nixos-rebuild.
  run = {
    source, backup, force, prune, deploy, targetKind, targetPath,
  }: let
    args = {
      inherit source backup force prune;
      target = targets.${targetKind} targetPath;
    };
  in
    if deploy == null then pkgs.populate args
    else pkgs.krops.writeDeploy "deploy"
      (args // { useNixOutputMonitor = false; } // deploy);

  builderArgs = {
    inherit lib run;
    inherit (krops) evalSource;
    checksDuringEvaluation = true;
    url = "http://deployer:8000";
    gitUrl = "git://deployer/gitsrc.git";
    inherit remoteHost;
    agePath = "${pkgs.age}/bin/age";
    inherit gitHead gitFirst;
    rsyncVersion = pkgs.rsync.version;
  };

  populateScenarios = lib.concatLists (builtins.attrValues
    (import (populateTests + "/scenarios.nix") builderArgs));
  kropsScenarios = import ./scenarios.nix (builderArgs // { inherit targets; });

  # Names of the scenarios of the smoke test, besides populate's.
  smokeNames = import (populateTests + "/smoke.nix") ++ [
    "deploy-local-buildTarget0-etcFlake0-flakefile"
    "deploy-sudo-allocateTTY"
  ];

  scenarios = {
    inherit (kropsScenarios) deploy;
    populate = builtins.filter
      (scenario: scenario.refusals || builtins.elem scenario.name smokeNames)
      populateScenarios;
  };
  allScenarios = populateScenarios ++ lib.concatLists (builtins.attrValues kropsScenarios);

  # The stand-in for nixos-rebuild replaces it on both machines.
  module = { pkgs, ... }: {
    environment.systemPackages = [
      (pkgs.writeScriptBin "nixos-rebuild" (builtins.readFile ./nixos-rebuild.sh))
    ];
    system.disableInstallerTools = true;
  };

  vm = name: scenarios: import (populateTests + "/vm.nix") {
    inherit pkgs gitHead scenarios module;
    name = "krops-${name}";
  };

  # VM tests of those of the groups of scenarios that are, or aren't,
  # exhaustive, named after the groups with prefix in front.
  testsOf = exhaustive: prefix: lib.mapAttrs
    (name: scenarios: vm (prefix + name) scenarios)
    (lib.filterAttrs (_: scenarios: scenarios != [])
      (builtins.mapAttrs
        (_: builtins.filter (scenario: scenario.exhaustive == exhaustive))
        scenarios));

  smokeScenarios = let
    selected = builtins.filter (scenario: builtins.elem scenario.name smokeNames) allScenarios;
    missing = lib.subtractLists (map (scenario: scenario.name) selected) smokeNames;
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

# The remote target must not count as local wherever this gets evaluated.
assert !(krops.isLocalTarget (targets.remote "/"));

  testsOf false ""
  # Not built by nix-build tests either, which runs these scenarios anyway.
  // {
    smoke.smoke = vm "smoke" smokeScenarios;
    only.only = vm "only" onlyScenarios;
  }
  # An attribute set without recurseForDerivations, so nix-build tests
  # doesn't build them.
  // { exhaustive = testsOf true "exhaustive-"; }
