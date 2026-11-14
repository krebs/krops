# The scenario builder of populate's tests, which krops' tests use as well.
# A scenario prepares the target directory, then runs its phases.  Each phase
# runs populate, or something running it, expecting it to succeed, to fail
# with a message, or to refuse its arguments, and checks the result on the
# target.  Refusals checked during evaluation get checked here and don't run.
{
  # nixpkgs' lib.
  lib,
  # evalSource of populate's Nix library.
  evalSource,
  # Function from a phase's arguments, { source, backup, force, prune,
  # deploy, targetKind, targetPath }, to the command running the phase.
  # source is what evalSource returns; deploy is null, or arguments for
  # running populate in a deployment.
  run,
  # Whether the command checks populate's arguments during evaluation, so
  # phases expecting a refusal expect evaluation to fail, instead of
  # populate refusing when it runs.
  checksDuringEvaluation,
  # Where the deploying machine serves /fixtures/www via HTTP.
  url,
  # URL of the Git repository /fixtures/git/gitsrc.git.
  gitUrl,
  # Host name of the remote target.
  remoteHost,
  # Absolute path of age on the deploying machine.
  agePath,
  # HEAD of /fixtures/gitsrc, and its parent.
  gitHead,
  gitFirst,
  # Version of rsync on the deploying machine.
  rsyncVersion,
}:

let
  inherit (lib)
    attrNames concatMap concatStringsSep foldl' isBool mapAttrsToList
    optional optionalAttrs optionals optionalString;

  prelude = ". ${./lib.sh}\n";

  cartesian = attrs: foldl'
    (acc: name: concatMap
      (combination: map
        (value: combination // { ${name} = value; })
        attrs.${name})
      acc)
    [{}]
    (attrNames attrs);

  flagsName = flags: concatStringsSep "-" (mapAttrsToList
    (name: value: name + (if isBool value then (if value then "1" else "0") else value))
    flags);

  alt = { alt.file = "/fixtures/alt"; };

  # A path on a target of kind targetKind, as populate names it in what it
  # prints.
  targetName = targetKind: path: {
    local = "";
    remote = "${remoteHost}:";
    sudo = "deploy@${remoteHost}:";
  }.${targetKind} + path;

  # How a source draws inputs from other sources: not at all, by rewriting
  # the lock file of its flake, or by a generated flake.
  inputModes = [ "none" "rewrite" "generated" ];

  # The options of a source drawing inputs in mode.
  drawInputs = mode: inputs: optionalAttrs (mode != "none") ({
    inherit inputs;
  } // optionalAttrs (mode == "generated") {
    rewriteLock = false;
  });

  # The flake of source x that has its inputs drawn in mode.
  flakeOf = mode:
    if mode == "generated" then ''"$T"/.populate/flakes/x'' else ''"$T"/x'';

  # Builds a scenario from a name, a target kind, and phases with sources.
  # Isolated scenarios start with no target directories and a collected store
  # on both machines, so no other scenario's store paths or roots stand in for
  # missing ones.  An exhaustive scenario covers a combination that no code
  # path tells apart from the ones the other scenarios cover, so it only runs
  # in the exhaustive tests.
  scenario = {
    name, targetKind, node ? null, isolate ? false, exhaustive ? false,
    prepare ? "", prepareDeployer ? null, phases,
  }: let
    path = "/var/krops/${name}";
    vars = "T=${path}\n";
    # A phase expecting evaluation to fail, if checksDuringEvaluation, or else
    # populate to refuse with the message refused, has a control: sources that
    # differ only in what makes evaluation fail, or a function returning them
    # for the phase's sources, and that must evaluate.  So the phase doesn't
    # pass for failing for an unrelated reason, e.g. a misspelt option.
    # targetPath deploys to another path than the scenario's target
    # directory, and controlTargetPath is the control for a path that makes
    # evaluation fail.  env sets environment variables for populate, as
    # arguments of env.  interrupt ends populate after that many seconds,
    # which it's expected not to finish before.  output lists what a
    # succeeding populate is expected to print, and unexpected what populate
    # is expected not to print, succeeding or not.  expect.fail is what a
    # failing populate is expected to print, and expect.status, if given,
    # its exit status.
    phase = {
      sources, backup ? false, prune ? false, deploy ? null,
      targetPath ? path, env ? "", interrupt ? null, output ? [],
      unexpected ? [],
      expect ? "success", refused ? null, control ? null, controlTargetPath ? null,
      check ? "", mutate ? null, checkDeployer ? null, mutateDeployer ? null,
    }: let
      command = sources: targetPath: run {
        source = evalSource [ sources ];
        inherit backup prune deploy targetKind targetPath;
        force = true;
      };
      evaluates = sources: targetPath:
        (builtins.tryEval
          (builtins.seq (toString (command sources targetPath)) true)).success;
      script = text: if text == null then null else prelude + vars + text;
      # Without checks during evaluation, populate refuses when it runs.
      expect' =
        if expect == "eval-error" && !checksDuringEvaluation then
          if refused == null then
            throw "scenario ${name}: expecting a refusal needs refused, what populate says"
          else { fail = refused; }
        else expect;
    in
      if expect' == "eval-error" then
        if control == null && controlTargetPath == null then
          throw "scenario ${name}: expecting evaluation to fail needs a control"
        else if evaluates sources targetPath then
          throw "scenario ${name}: populate evaluates, but is expected to fail"
        else if !(
          if controlTargetPath != null then evaluates sources controlTargetPath
          else evaluates
            (if lib.isFunction control then control sources else control)
            targetPath
        ) then
          throw "scenario ${name}: the control doesn't evaluate either"
        else
          null
      else {
        populate = toString (command sources targetPath);
        inherit env interrupt output unexpected;
        expect = if expect' == "success" then null else expect'.fail;
        status = if expect' == "success" then null else expect'.status or null;
        # No phase gets around checking the canaries.
        check = script (check + "\ncanary_check\n");
        mutate = script mutate;
        checkDeployer = script checkDeployer;
        mutateDeployer = script mutateDeployer;
      };
  in {
    inherit name isolate exhaustive;
    # Whether a phase expects a refusal, which krops' tests check during
    # evaluation.
    refusals = lib.any (phase: phase.expect or null == "eval-error") phases;
    node =
      if node != null then node
      else if targetKind == "local" then "deployer"
      else "target";
    prepare = prelude + vars + ''
      rm -fR "$T"
    '' + prepare;
    prepareDeployer =
      if prepareDeployer == null then null else prelude + vars + prepareDeployer;
    # For all machines: before the scenario, and after it for the ones its
    # checks don't run on.
    canarySetup = prelude + "canary_setup\n";
    canaryCheck = prelude + "canary_check\n";
    phases = lib.filter (x: x != null) (map phase phases);
  };

  # Same sources twice, so the second phase checks redeploying.
  twice = phase: [ phase phase ];

  targetKinds = [ "local" "remote" "sudo" ];

  # Scenarios for all combinations of options and target kinds.  f gets the
  # options and the scenario's name, target kind, and target directory, and
  # returns the scenario's arguments, or null for invalid combinations.
  matrix = type: options: f:
    concatMap
      (targetKind: lib.filter (x: x != null) (map
        (flags: let
          name = "${type}-${targetKind}" +
            optionalString (flags != {}) "-${flagsName flags}";
          args = f flags { inherit name targetKind; path = "/var/krops/${name}"; };
        in
          if args == null then null
          else scenario ({ inherit name targetKind; } // args))
        (cartesian options)))
      targetKinds;

  # Checks that the source at $T/x is a link to a store path, or to the
  # subdirectory sub therein, or a writable directory if materialized, and
  # evaluates the attribute attr of the flake there, or of its generated
  # flake, after collecting garbage.
  checkFlake = {
    attr, expected, subdir ? false, generated ? false, materialized ? false,
  }: (if materialized then ''
    test -d "$T"/x && ! test -L "$T"/x || fail "x isn't a directory"
    test -w "$T"/x/flake.nix || fail "flake.nix isn't writable"
  '' else ''
    link=$(readlink "$T"/x)
    ${if subdir then ''
      expect_eq subdirectory "$(basename "$link")" sub
      link=$(dirname "$link")
    '' else ""}
    expect_eq "store directory" "$(dirname "$link")" /nix/store
  '') + ''
    test ! -e "$T"/.populate/flake-uploads || fail "upload directory remains"
    gc
    expect_eq ${attr} "$(nix_eval ${
      if generated then ''"$T"/.populate/flakes/x'' else ''"$T"/x''
    }#${attr})" ${lib.escapeShellArg expected}
  '';

  copyingWithSudo = flags: ctx:
    ctx.targetKind == "sudo" && !(flags.fetchOnTarget or false);

  # The sources with fetchOnTarget set for all flake and flake-input sources,
  # the control for copying flakes to targets using sudo.
  withFetchOnTarget = lib.mapAttrs (_: lib.mapAttrs (type: options:
    if lib.elem type [ "flake" "flake-input" ]
      then options // { fetchOnTarget = true; }
      else options));

  # A phase copying flakes to a target using sudo, which isn't supported,
  # and gets refused during evaluation.
  refuseCopyingWithSudo = {
    expect = "eval-error";
    refused = "copying flakes to targets with sudo is not supported";
    control = withFetchOnTarget;
  };

in {
  inherit lib url gitUrl remoteHost agePath gitHead gitFirst rsyncVersion;
  inherit (lib)
    attrNames concatMap concatStringsSep foldl' isBool mapAttrsToList
    optional optionalAttrs optionals optionalString;
  inherit
    prelude cartesian flagsName alt targetName
    inputModes drawInputs flakeOf scenario twice
    targetKinds matrix checkFlake copyingWithSudo withFetchOnTarget
    refuseCopyingWithSudo;
}
