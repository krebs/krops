# NixOS VM tests for populate: one test per source type, one for features
# spanning sources, one for edge cases of flakes, and one for staying inside
# the target directory.  Each runs the program, with the sources as JSON
# from populate's Nix library, and target strings, which leave the user and
# whether the target is local to populate to decide.  Build all with
# nix-build in this directory, or one with, e.g., nix-build -A flake.  The
# exhaustive tests add the combinations of options that no code path tells
# apart from the ones the others cover; build them with nix-build -A
# exhaustive, or one with, e.g., nix-build -A exhaustive.flake.  The smoke
# test runs a few scenarios covering each source type and each kind of
# target in a single VM test, for checking changes quickly; build it with
# nix-build -A smoke.  nix-build -A only --argstr only REGEX runs the
# scenarios whose names match the regular expression REGEX in a single VM
# test, e.g. --argstr only 'lock-hooks-.*'.
{ pkgs ? import <nixpkgs> {}, only ? null }:

let
  inherit (pkgs) lib;

  populate-unwrapped = pkgs.callPackage ../. {};
  populateLib = import ../lib { inherit lib; };

  inherit (import ./fixtures.nix) gitHead gitFirst;

  remoteHost = "target";

  # rsync versions the scenarios depending on rsync's version run with.
  # callPackage adds override and overrideDerivation, which aren't versions.
  rsyncs = lib.filterAttrs
    (_: lib.isDerivation)
    (pkgs.callPackage ./rsync.nix {});

  # A script running populate for a phase, with the tools it runs in front
  # of PATH, and the sources on a file descriptor of their own, so the
  # commands populate runs keep standard input.  Store paths in the sources
  # stay dependencies of the script.
  runWith = rsync: {
    source, backup, force, prune, deploy, targetKind, targetPath,
  }:
    if deploy != null then throw "populate's tests don't deploy" else
    pkgs.writers.writeDash "populate" /* sh */ ''
      set -efu
      PATH=${lib.makeBinPath [
        pkgs.coreutils pkgs.findutils pkgs.git pkgs.nix pkgs.openssh pkgs.pass
        pkgs.passage rsync
      ]}''${PATH:+:$PATH}
      export PATH
      exec ${populate-unwrapped}/bin/populate ${lib.escapeShellArgs (
        lib.optional backup "--backup" ++
        lib.optional force "--force" ++
        lib.optional prune "--prune" ++
        [ "/dev/fd/3" ] ++
        {
          local = [];
          remote = [ "root@${remoteHost}" ];
          sudo = [ "deploy@${remoteHost}" "--sudo" ];
        }.${targetKind} ++
        [ "--path" targetPath ]
      )} 3<<'EOF'
      ${builtins.toJSON source}
      EOF
    '';

  # The scenarios, with populate using rsync.
  scenariosWith = rsync: import ./scenarios.nix {
    inherit lib;
    inherit (populateLib) evalSource;
    run = runWith rsync;
    checksDuringEvaluation = false;
    url = "http://deployer:8000";
    gitUrl = "git://deployer/gitsrc.git";
    inherit remoteHost;
    agePath = "${pkgs.age}/bin/age";
    inherit gitHead gitFirst;
    rsyncVersion = rsync.version;
  };
  scenarios = scenariosWith pkgs.rsync;

  vm = name: scenarios: rsync: import ./vm.nix {
    inherit pkgs gitHead scenarios rsync;
    name = "populate-${name}";
  };

  # VM tests of those of the groups of scenarios that are, or aren't,
  # exhaustive, named after the groups with prefix in front.
  testsOf = exhaustive: prefix: lib.mapAttrs
    (name: scenarios: vm (prefix + name) scenarios pkgs.rsync)
    (lib.filterAttrs (_: scenarios: scenarios != [])
      (builtins.mapAttrs
        (_: builtins.filter (scenario: scenario.exhaustive == exhaustive))
        scenarios));

  allScenarios = lib.concatLists (builtins.attrValues scenarios);

  # The scenarios named names, failing if one is missing.
  named = what: names: let
    selected = builtins.filter (scenario: builtins.elem scenario.name names) allScenarios;
    missing = lib.subtractLists (map (scenario: scenario.name) selected) names;
  in
    if missing != [] then
      throw "tests: ${what} names missing scenarios: ${toString missing}"
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
  # Not built by nix-build either, which runs these scenarios anyway.
  // {
    smoke.smoke = vm "smoke" (named "smoke test" (import ./smoke.nix)) pkgs.rsync;
    only.only = vm "only" onlyScenarios pkgs.rsync;
  }
  # An attribute set without recurseForDerivations, so nix-build doesn't
  # build them.
  // { exhaustive = testsOf true "exhaustive-"; }
  // lib.mapAttrs'
    (version: rsync: {
      name = "rsync-${builtins.replaceStrings [ "." ] [ "-" ] version}";
      value = vm "rsync-${version}"
        (builtins.filter
          (scenario: lib.hasInfix "insecureLinks" scenario.name)
          (scenariosWith rsync).file)
        rsync;
    })
    rsyncs
