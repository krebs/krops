# Test scenarios for populate: every combination of each source type's
# options, deployed to the local machine, to a remote target as root, and to
# a remote target using sudo, plus scenarios for features spanning sources.
#
# A scenario prepares the target directory, then runs its phases.  Each phase
# runs populate, or writeDeploy with a stand-in for nixos-rebuild, expecting
# it to succeed or to fail with a message, and checks the result on the
# target.  Phases expecting evaluation to fail get checked here and don't run.
{
  # nixpkgs' lib.
  lib,
  # krops' lib.
  krops,
  # Function from populate's arguments to the command running populate.
  populate,
  # krops' writeDeploy.
  writeDeploy,
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

  alt = { alt.file = "/fixtures/alt"; };

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
    target = targets.${targetKind} path;
    vars = "T=${path}\n";
    # A phase expecting evaluation to fail has a control: sources that
    # differ only in what makes evaluation fail, or a function returning them
    # for the phase's sources, and that must evaluate.  So the phase doesn't
    # pass for failing for an unrelated reason, e.g. a misspelt option.
    # targetPath deploys to another path than the scenario's target
    # directory, and controlTargetPath is the control for a path that makes
    # evaluation fail.  env sets environment variables for populate, as
    # arguments of env.  interrupt ends populate after that many seconds,
    # which it's expected not to finish before.  output lists what a
    # succeeding populate is expected to print.
    phase = {
      sources, backup ? false, prune ? false, deploy ? null,
      targetPath ? path, env ? "", interrupt ? null, output ? [],
      expect ? "success", control ? null, controlTargetPath ? null,
      check ? "", mutate ? null, checkDeployer ? null, mutateDeployer ? null,
    }: let
      command = sources: targetPath: let
        args = {
          source = krops.evalSource [ sources ];
          inherit backup prune;
          target = target // { path = targetPath; };
          force = true;
        };
      in
        if deploy == null then populate args
        else writeDeploy "deploy" (args // { useNixOutputMonitor = false; } // deploy);
      evaluates = sources: targetPath:
        (builtins.tryEval
          (builtins.seq (toString (command sources targetPath)) true)).success;
      script = text: if text == null then null else prelude + vars + text;
    in
      if expect == "eval-error" then
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
        inherit env interrupt output;
        expect = if expect == "success" then null else expect.fail;
        # No phase gets around checking the canaries.
        check = script (check + "\ncanary_check\n");
        mutate = script mutate;
        checkDeployer = script checkDeployer;
        mutateDeployer = script mutateDeployer;
      };
  in {
    inherit name isolate exhaustive;
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

in

# The remote target must not count as local wherever this gets evaluated.
assert !(krops.isLocalTarget (targets.remote "/"));

{

  derivation = matrix "derivation" {} (_: _: {
    phases = twice {
      sources.x.derivation = ''
        derivation {
          name = "krops-test";
          system = builtins.currentSystem;
          builder = "/bin/sh";
          args = [ "-c" "echo built > $out" ];
        }
      '';
      check = ''
        gc
        expect_eq x "$(cat "$T"/x)" built
      '';
    };
  });

  file = let
    f = flags: _: {
      # Drawing inputs happens after rsync, so it doesn't depend on rsync's
      # options.
      exhaustive = flags.inputs != "none" &&
        (flags.checksum || flags.deleteExcluded || flags.filters);
      prepare = ''
        mkdir -p "$T"/x
        echo old > "$T"/x/skip-ex
        echo old > "$T"/x/skip-f
        echo stale > "$T"/x/stale
        echo BBBB > "$T"/x/same
        touch -d @1000000000 "$T"/x/same
      '';
      phases = twice {
        sources = {
          x.file = {
            path = "/fixtures/filesrc";
            useChecksum = flags.checksum;
            inherit (flags) deleteExcluded;
            exclude = optional (flags.exclude or false) "skip-ex";
            filters = optional flags.filters { type = "exclude"; pattern = "skip-f"; };
          } // drawInputs flags.inputs { dep.follows = "alt"; };
        } // optionalAttrs (flags.inputs != "none") alt;
        check = let
          excluded = file: set: ''
            ${if !set then ''
              expect_eq ${file} "$(cat "$T"/x/${file})" src
            '' else if flags.deleteExcluded then ''
              test ! -e "$T"/x/${file} || fail "${file} not deleted"
            '' else ''
              expect_eq ${file} "$(cat "$T"/x/${file})" old
            ''}
          '';
        in ''
          expect_eq keep "$(cat "$T"/x/keep)" keep
          ${excluded "skip-ex" (flags.exclude or false)}
          ${excluded "skip-f" flags.filters}
          ${if flags.deleteExcluded then ''
            test ! -e "$T"/x/stale || fail "stale not deleted"
          '' else ''
            expect_eq stale "$(cat "$T"/x/stale)" stale
          ''}
          expect_eq same "$(cat "$T"/x/same)" ${if flags.checksum then "AAAA" else "BBBB"}
        '' + optionalString (flags.inputs != "none") ''
          # Inputs not drawn from sources aren't delivered, so this needs the
          # network and can't collect garbage before.
          expect_eq msg "$(nix_eval_online ${flakeOf flags.inputs}#msg)" top:alt,sub
        '';
      };
    };
  in
    matrix "file" {
      checksum = [ false true ];
      deleteExcluded = [ false true ];
      filters = [ false true ];
      inputs = inputModes;
    } f
    ++ [
      # The deprecated exclude option, once, because it warns.
      (scenario (let
        args = f {
          checksum = false;
          deleteExcluded = true;
          exclude = true;
          filters = false;
          inputs = "none";
        } null;
      in args // {
        name = "file-local-exclude";
        targetKind = "local";
        phases = [ (builtins.head args.phases) ];
      }))
    ]
    # A source whose .rsync-filter rsync 3.5.0 and later can't read, because
    # it's reached through a symlink that neither root nor the user deploying
    # owns.  (Running as root, the scenarios can't use the other common
    # cause, a directory on the way that the user may enter but not read.)
    ++ concatMap (targetKind: map (insecureLinks: let
      affected = lib.versionAtLeast rsyncVersion "3.5.0";
      excluded = !affected || insecureLinks == true;
    in scenario {
      name = "file-${targetKind}-insecureLinks" +
        (if insecureLinks == null then "Null" else if insecureLinks then "True" else "False");
      inherit targetKind;
      prepare = ''
        mkdir -p "$T"/x
        echo old > "$T"/x/garbage
      '';
      phases = twice ({
        sources.x.file = { path = "/fixtures/filtered-link"; inherit insecureLinks; };
      } // (if affected && insecureLinks == null then {
        expect.fail = "can't read /fixtures/filtered-link/.rsync-filter, so it would sync /fixtures/filtered-link/ without it.";
      } else {
        output = optional affected (
          if insecureLinks
            then "can't read /fixtures/filtered-link/.rsync-filter; it reads it with --insecure-links anyway, because insecureLinks is true."
            else "can't read /fixtures/filtered-link/.rsync-filter, so it syncs /fixtures/filtered-link/ without it, because insecureLinks is false."
        );
        check = ''
          expect_eq keep "$(cat "$T"/x/keep)" keep
          ${if excluded then ''
            test ! -e "$T"/x/garbage || fail "garbage not excluded"
          '' else ''
            expect_eq garbage "$(cat "$T"/x/garbage)" garbage
          ''}
        '';
      }));
    }) [ null true false ]) targetKinds
    ++ concatMap (targetKind: let
      affected = lib.versionAtLeast rsyncVersion "3.5.0";
      unreadable = name: { path, file, dir ? "x", env ? "" }: scenario {
        name = "file-${targetKind}-insecureLinks${name}";
        inherit targetKind;
        prepare = ''
          mkdir -p "$T"/${dir}
          echo old > "$T"/${dir}/garbage
        '';
        phases = twice ({
          sources.x.file = { inherit path; };
          inherit env;
        } // (if affected then {
          expect.fail = "can't read ${file}, so it would sync ${path}/ without it.";
        } else {
          check = ''
            expect_eq keep "$(cat "$T"/${dir}/keep)" keep
            test ! -e "$T"/${dir}/garbage || fail "garbage not excluded"
          '';
        }));
      };
    in [
      # The filter file is in the directory above what gets synced, where it
      # applies as well.
      (unreadable "Parent" {
        path = "/fixtures/filtered-parent-link/sub";
        file = "/fixtures/filtered-parent-link/.rsync-filter";
      })
      # The filter file is in a directory whose name rsync prints escaped
      # in the C locale.
      (unreadable "Name" {
        path = "/fixtures/filtered-name-link";
        file = "/fixtures/filtered-name-link/bär/.rsync-filter";
        dir = "x/bär";
        env = "LC_ALL=C";
      })
    ]) targetKinds;

  flake = matrix "flake" {
    kind = [ "git" "path" "subdir" "remote" ];
    fetchOnTarget = [ false true ];
    inputs = inputModes;
    materialize = [ false true ];
  } (flags: ctx: let
    flake = {
      git = "/fixtures/top";
      path = "path:/fixtures/top";
      subdir = "git+file:/fixtures/mono?dir=sub";
      remote = "${url}/remote.tar.gz";
    }.${flags.kind};
    msg = {
      git = "top:${if flags.inputs != "none" then "alt" else "dep+inner"},sub";
      path = msg.git;
      remote = "remote:${if flags.inputs != "none" then "alt" else "dep+inner"}";
    };
  in
    # The flake in a subdirectory has no inputs to draw from sources.
    if flags.kind == "subdir" && flags.inputs != "none" then null else {
    isolate = true;
    # Materializing copies what got delivered, whichever way, so it depends
    # on how inputs get drawn and on subdirectories, not on how the flake got
    # there.
    exhaustive = flags.materialize && !lib.elem flags.kind [ "git" "subdir" ];
    phases = twice ({
      sources = {
        x.flake = {
          url = flake;
          inherit (flags) fetchOnTarget materialize;
        } // drawInputs flags.inputs { dep.follows = "alt"; };
      } // optionalAttrs (flags.inputs != "none") alt;
    } // (if copyingWithSudo flags ctx then {
      expect = "eval-error";
      control = withFetchOnTarget;
    } else {
      check = if flags.kind == "subdir" then checkFlake {
        attr = "who"; expected = "sub"; subdir = true;
        materialized = flags.materialize;
      } else checkFlake {
        attr = "msg"; expected = msg.${flags.kind};
        generated = flags.inputs == "generated";
        materialized = flags.materialize;
      };
    }));
  });

  flake-input = concatMap
    (name: matrix "flake-input-${lib.replaceStrings ["/"] ["."] name}" ({
      fetchOnTarget = [ false true ];
      materialize = [ false true ];
    } // optionalAttrs (name == "dep") {
      inputs = inputModes;
    }) (flags: ctx: let
      inputs = flags.inputs or "none";
    in {
      isolate = true;
      # Materializing copies what got delivered, whichever input it is.
      exhaustive = flags.materialize && name != "dep";
      phases = twice ({
        sources = {
          x.flake-input = {
            url = "/fixtures/top";
            inherit name;
            inherit (flags) fetchOnTarget materialize;
          } // drawInputs inputs { inner.follows = "alt"; };
        } // optionalAttrs (inputs != "none") alt;
      } // (if copyingWithSudo flags ctx then {
        expect = "eval-error";
        control = withFetchOnTarget;
      } else {
        check = {
          dep = checkFlake {
            attr = "greeting";
            expected = if inputs != "none" then "dep+alt" else "dep+inner";
            generated = inputs == "generated";
            materialized = flags.materialize;
          };
          "dep/inner" = checkFlake {
            attr = "who"; expected = "inner"; materialized = flags.materialize;
          };
          sub = checkFlake {
            attr = "who"; expected = "sub"; subdir = true;
            materialized = flags.materialize;
          };
        }.${name};
      }));
    }))
    [ "dep" "dep/inner" "sub" ];

  git = matrix "git" {
    shallow = [ false true ];
    fetchAlways = [ false true ];
    cleanExclude = [ false true ];
    inputs = inputModes;
  } (flags: _: let
    check = ''
      expect_eq HEAD "$(git -C "$T"/x rev-parse HEAD)" ${gitHead}
      expect_eq commits "$(git -C "$T"/x rev-list --count HEAD)" ${
        if flags.shallow then "1" else "2"
      }
      test -e "$T"/x/two || fail "two missing"
    '' + optionalString (flags.inputs == "generated") ''
      grep -q '"git+file:' "$T"/.populate/flakes/x/flake.nix ||
        fail "the Git work tree isn't referred to as git+file:"
    '' + optionalString (flags.inputs != "none") ''
      gc
      expect_eq msg "$(nix_eval ${flakeOf flags.inputs}#msg)" git:alt
    '';
    sources = ref: {
      x.git = {
        url = gitUrl;
        inherit ref;
        inherit (flags) shallow fetchAlways;
        clean.exclude = optional flags.cleanExclude "keepme";
      } // drawInputs flags.inputs { dep.follows = "alt"; };
    } // optionalAttrs (flags.inputs != "none") alt;
  in {
    # Drawing inputs happens after Git, so it doesn't depend on Git's
    # options.
    exhaustive = flags.inputs != "none" &&
      (flags.shallow || flags.fetchAlways || flags.cleanExclude);
    phases = [
      # The older commit first, so deploying HEAD changes the work tree, and
      # fetches if fetchAlways is set or the clone is shallow.
      {
        sources = sources gitFirst;
        check = ''
          expect_eq HEAD "$(git -C "$T"/x rev-parse HEAD)" ${gitFirst}
          expect_eq commits "$(git -C "$T"/x rev-list --count HEAD)" 1
          test ! -e "$T"/x/two || fail "two present"
        '';
      }
      {
        sources = sources gitHead;
        inherit check;
        mutate = ''
          echo junk > "$T"/x/junk
          echo keepme > "$T"/x/keepme
        '';
      }
      {
        sources = sources gitHead;
        check = check + ''
          test ! -e "$T"/x/junk || fail "junk not cleaned"
          ${if flags.cleanExclude then ''
            test -e "$T"/x/keepme || fail "keepme cleaned"
          '' else ''
            test ! -e "$T"/x/keepme || fail "keepme not cleaned"
          ''}
        '';
      }
    ];
  })
  ++ map (targetKind: scenario (let
    # The commit the first phase adds on top of gitHead, deterministic like
    # the ones fixtures.sh creates.
    gitThird = "c2e0f9d727337617a548284552909abe0f196d05";
  in {
    # A full clone fetches a commit that appears on the server afterwards,
    # also without fetchAlways.
    name = "git-${targetKind}-fetch";
    inherit targetKind;
    prepareDeployer = ''
      git -C /fixtures/git/gitsrc.git update-ref -d refs/heads/extra
    '';
    phases = [
      {
        sources.x.git = { url = gitUrl; ref = gitHead; };
        check = ''
          expect_eq HEAD "$(git -C "$T"/x rev-parse HEAD)" ${gitHead}
        '';
        mutateDeployer = ''
          export GIT_AUTHOR_NAME=krops GIT_AUTHOR_EMAIL=spam@krebsco.de
          export GIT_COMMITTER_NAME=krops GIT_COMMITTER_EMAIL=spam@krebsco.de
          export GIT_AUTHOR_DATE='1000000000 +0000' GIT_COMMITTER_DATE='1000000000 +0000'
          export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
          cd /fixtures/gitsrc
          git checkout -q -B extra ${gitHead}
          echo three > three
          git add -A
          git commit -q -m three
          git push -q -f /fixtures/git/gitsrc.git extra
          git checkout -q master
          expect_eq "third commit" "$(git rev-parse extra)" ${gitThird}
        '';
      }
      {
        sources.x.git = { url = gitUrl; ref = gitThird; };
        check = ''
          expect_eq HEAD "$(git -C "$T"/x rev-parse HEAD)" ${gitThird}
          test -e "$T"/x/three || fail "three missing"
        '';
      }
    ];
  })) targetKinds
  # A git source stops drawing inputs: its lock file, which Nix created and
  # staged, goes, so the work tree is as the commit has it.
  ++ map (targetKind: scenario {
    name = "git-${targetKind}-dropInputs";
    inherit targetKind;
    phases = [
      {
        sources = alt // {
          x.git = { url = gitUrl; ref = gitHead; inputs.dep.follows = "alt"; };
        };
        check = ''
          expect_eq msg "$(nix_eval_online git+file:"$T"/x#msg)" git:alt
        '';
      }
      {
        sources = alt // { x.git = { url = gitUrl; ref = gitHead; }; };
        check = ''
          expect_eq status "$(git -C "$T"/x status --porcelain)" ""
        '';
      }
    ];
  }) targetKinds;

  pass = matrix "pass" {
    store = [ "pass" "pass-git" ];
  } (flags: _: {
    phases = twice {
      sources.x.pass = { dir = "/fixtures/${flags.store}"; name = "x"; };
      check = ''
        expect_eq a "$(cat "$T"/x/a)" secret-a
      '';
    };
  });

  passage = matrix "passage" {
    age = [ "default" "path" ];
    dir = [ "store" "subdir" ];
  } (flags: _: {
    phases = twice {
      sources.x.passage = {
        dir = "/fixtures/passage/store" + optionalString (flags.dir == "subdir") "/x";
        identities_file = "/fixtures/passage/identities";
      } // optionalAttrs (flags.age == "path") {
        age = agePath;
      };
      check = ''
        expect_eq a "$(cat "$T"/x/${optionalString (flags.dir == "store") "x/"}a)" secret-a
      '';
    };
  });

  pipe = matrix "pipe" {} (_: _: {
    phases = twice {
      sources.x.pipe = "/fixtures/pipe";
      check = ''
        expect_eq x "$(cat "$T"/x)" piped
      '';
    };
  });

  symlink = matrix "symlink" {
    absolute = [ false true ];
    inputs = [ false true ];
  } (flags: ctx: let
    target = optionalString flags.absolute "${ctx.path}/" + "topcopy";
  in {
    phases = twice {
      sources = {
        x.symlink = {
          inherit target;
          inputs = optionalAttrs flags.inputs { dep.follows = "alt"; };
        };
        topcopy.file = "/fixtures/filesrc";
      } // optionalAttrs flags.inputs alt;
      check = ''
        expect_eq link "$(readlink "$T"/x)" ${target}
        test -e "$T"/x/flake.nix || fail "flake.nix missing"
      '' + optionalString flags.inputs ''
        expect_eq msg "$(nix_eval_online "$T"/.populate/flakes/x#msg)" top:alt,sub
      '';
    };
  });

  # writeDeploy's arguments to nixos-rebuild, which a stand-in records.
  # flake is what gets deployed: nothing, or a flake from a file, git, or
  # flake source, or one whose inputs get drawn from a source, by rewriting
  # its lock file or through a generated flake.
  deploy = matrix "deploy" {
    flake = [ "none" "file" "git" "source" "rewrite" "generated" ];
    etcFlake = [ false true ];
    buildTarget = [ false true ];
  } (flags: ctx: let
    target = targets.${ctx.targetKind} ctx.path;
    buildTarget = targets.local "${ctx.path}-build";
    build = if flags.buildTarget then buildTarget else target;
    # Without a user, ssh decides.
    userHost = target:
      optionalString (target.user != null && target.user != "") "${target.user}@" +
      target.host;
    expected = [ "switch" ]
      ++ optionals flags.buildTarget [
        "--build-host" (userHost buildTarget)
        "--target-host" (userHost target)
      ]
      ++ optional (flags.buildTarget && target.sudo) "--use-remote-sudo";
    # The flake's directory, which gets deployed by its resolved path, as
    # path:, so no enclosing Git work tree captures it, or as the Git work
    # tree it is.
    flakeDir =
      if flags.flake == "generated" then ".populate/flakes/x" else "x";
    scheme = if flags.flake == "git" then "git+file" else "path";
  in
    # The local target can't have another build target.
    if flags.buildTarget && ctx.targetKind == "local" then null else {
      node = if flags.buildTarget then "deployer" else null;
      # /etc/nixos/flake.nix only matters if no flake gets deployed.
      exhaustive = flags.etcFlake && flags.flake != "none";
      # Each scenario creates or removes /etc/nixos/flake.nix.
      prepare = ''
        rm -f /tmp/nixos-rebuild.log
        ${if flags.etcFlake then ''
          mkdir -p /etc/nixos
          touch /etc/nixos/flake.nix
        '' else ''
          rm -f /etc/nixos/flake.nix
        ''}
      '';
      phases = twice {
        sources = {
          none.x.file = "/fixtures/alt";
          file.x.file = "/fixtures/alt";
          git.x.git = { url = gitUrl; ref = gitHead; };
        }.${flags.flake} or (alt // {
          x.flake = {
            url = "/fixtures/top";
            fetchOnTarget = ctx.targetKind == "sudo";
          } // drawInputs (if flags.flake == "source" then "none" else flags.flake) {
            dep.follows = "alt";
          };
        });
        deploy = {
          flake = if flags.flake == "none" then null else "x";
        } // optionalAttrs flags.buildTarget {
          inherit buildTarget;
        };
        check = ''
          expect_eq user "$(sed -n 1p /tmp/nixos-rebuild.log)" 0
          expect_eq NIX_PATH "$(sed -n 2p /tmp/nixos-rebuild.log)" ${build.path}
          expected=${lib.escapeShellArg (concatStringsSep " " expected)}
          ${if flags.flake == "none" then optionalString flags.etcFlake ''
            expected="$expected --no-flake"
          '' else ''
            expected="$expected --flake ${scheme}:$(readlink -f ${build.path}/${flakeDir})"
          ''}
          expect_eq arguments "$(sed -n 3p /tmp/nixos-rebuild.log)" "$expected"
        '';
      };
    });

  # Features spanning several sources.
  features = concatMap (targetKind: let
    s = name: args: scenario ({
      name = "${name}-${targetKind}";
      inherit targetKind;
      isolate = true;
    } // args);
    copying = targetKind != "sudo";
    fetchOnTarget = !copying;
    # A scenario for each way of drawing inputs, which f gets as mode, along
    # with draw, which adds inputs drawn that way to a source's options, and
    # flake, which gives the flake to evaluate for a source.
    modes = name: f: map
      (mode: s "${name}-${mode}" (f {
        draw = drawInputs mode;
        flake = n:
          if mode == "generated" then ''"$T"/.populate/flakes/${n}'' else ''"$T"/${n}'';
        inherit mode;
      }))
      [ "rewrite" "generated" ];
  in lib.flatten [
    # A source draws an input from a source that draws inputs itself.
    (modes "chain" ({ draw, flake, ... }: {
      phases = twice {
        sources = alt // {
          a.flake = { url = "/fixtures/top"; inherit fetchOnTarget; } // draw { dep.follows = "b"; };
          b.flake-input = {
            url = "/fixtures/top"; name = "dep"; inherit fetchOnTarget;
          } // draw { inner.follows = "alt"; };
        };
        check = ''
          gc
          expect_eq msg "$(nix_eval ${flake "a"}#msg)" top:dep+alt,sub
        '';
      };
    }))
    # An input of an input drawn from a source gets drawn from another
    # source.
    (modes "nested" ({ draw, flake, ... }: {
      phases = twice {
        sources = alt // {
          x.flake = {
            url = "/fixtures/top"; inherit fetchOnTarget;
          } // draw { dep = { follows = "b"; inputs.inner.follows = "alt"; }; };
          b.flake-input = { url = "/fixtures/top"; name = "dep"; inherit fetchOnTarget; };
        };
        check = ''
          gc
          expect_eq msg "$(nix_eval ${flake "x"}#msg)" top:dep+alt,sub
        '';
      };
    }))
    # The lock file gets rewritten or generated again when a source inputs
    # get drawn from changes.
    (modes "relock" ({ draw, flake, ... }: let
      x.file = { path = "/fixtures/filesrc"; } // draw { dep.follows = "a"; };
    in {
      phases = [
        {
          sources = { inherit x; a.file = "/fixtures/alt"; };
          check = ''
            expect_eq msg "$(nix_eval_online ${flake "x"}#msg)" top:alt,sub
          '';
        }
        {
          sources = { inherit x; a.file = "/fixtures/alt2"; };
          check = ''
            expect_eq msg "$(nix_eval_online ${flake "x"}#msg)" top:alt2,sub
          '';
        }
      ];
    }))
    # What drawing inputs needs gets removed once a source draws no inputs
    # anymore.
    (modes "removal" ({ draw, mode, ... }: let
      state = {
        rewrite = "derived/x/result";
        generated = "flakes/x/flake.lock";
      }.${mode};
    in {
      phases = [
        {
          sources = alt // {
            x.flake = { url = "/fixtures/top"; inherit fetchOnTarget; } // draw { dep.follows = "alt"; };
          };
          check = ''
            test -e "$T"/.populate/${state} || fail "${state} missing"
          '';
        }
        {
          sources = alt // {
            x.flake = { url = "/fixtures/top"; inherit fetchOnTarget; };
          };
          check = ''
            test ! -e "$T"/.populate/${dirOf state} || fail "${dirOf state} remains"
          '' + checkFlake { attr = "msg"; expected = "top:dep+inner,sub"; };
        }
      ];
    }))
    # Patches get applied in order to a copy, which becomes a store path and
    # gets made again only when the patches change.
    (s "patches" (let
      x = patches: {
        x.flake-input = {
          url = "/fixtures/top"; name = "dep"; inherit fetchOnTarget patches;
        };
      };
      both = x [ "/fixtures/patches/hello.patch" "/fixtures/patches/hello2.patch" ];
    in {
      phases = [
        {
          sources = both;
          check = checkFlake { attr = "greeting"; expected = "hello2+inner"; };
          # The key changes whenever the copy gets made again, which
          # the store path doesn't show, being the same.
          mutate = ''
            readlink "$T"/x > "$T".first
            stat -c %y "$T"/.populate/derived/x/key > "$T".key
          '';
        }
        {
          sources = both;
          check = checkFlake { attr = "greeting"; expected = "hello2+inner"; } + ''
            expect_eq "store path" "$(readlink "$T"/x)" "$(cat "$T".first)"
            expect_eq "copy made at" "$(stat -c %y "$T"/.populate/derived/x/key)" "$(cat "$T".key)"
          '';
        }
        {
          sources = x [ "/fixtures/patches/hello.patch" ];
          check = checkFlake { attr = "greeting"; expected = "hello+inner"; } + ''
            test "$(readlink "$T"/x)" != "$(cat "$T".first)" || fail "store path unchanged"
            expect_eq patches "$(ls "$T"/.populate/patches/x)" 0001-hello.patch
          '';
        }
        {
          sources = x [];
          check = checkFlake { attr = "greeting"; expected = "dep+inner"; } + ''
            test ! -e "$T"/.populate/patches || fail "patches remain"
            test ! -e "$T"/.populate/derived || fail "derived remains"
          '';
        }
      ];
    }))
    (s "patch-fails" {
      phases = [{
        sources.x.flake-input = {
          url = "/fixtures/top"; name = "dep"; inherit fetchOnTarget;
          patches = [ "/fixtures/patches/bad.patch" ];
        };
        expect.fail = "error: patch bad.patch does not apply to source x";
      }];
    })
    # Patches apply in the subdirectory the target path shows.
    (s "patch-subdir" {
      phases = twice {
        sources.x.flake-input = {
          url = "/fixtures/top"; name = "sub"; inherit fetchOnTarget;
          patches = [ "/fixtures/patches/sub.patch" ];
        };
        check = checkFlake { attr = "who"; expected = "patched"; subdir = true; };
      };
    })
    # A copy with a rewritten lock file gets made again only when a source
    # it draws inputs from changes.
    (s "rewrite-cache" (let
      x.flake-input = {
        url = "/fixtures/top"; name = "dep"; inherit fetchOnTarget;
        inputs.inner.follows = "a";
      };
    in {
      phases = [
        {
          sources = { inherit x; a.file = "/fixtures/alt"; };
          check = checkFlake { attr = "greeting"; expected = "dep+alt"; };
          # The key changes whenever the copy gets made again, which
          # the store path doesn't show, being the same.
          mutate = ''
            readlink "$T"/x > "$T".first
            stat -c %y "$T"/.populate/derived/x/key > "$T".key
          '';
        }
        {
          sources = { inherit x; a.file = "/fixtures/alt"; };
          check = checkFlake { attr = "greeting"; expected = "dep+alt"; } + ''
            expect_eq "store path" "$(readlink "$T"/x)" "$(cat "$T".first)"
            expect_eq "copy made at" "$(stat -c %y "$T"/.populate/derived/x/key)" "$(cat "$T".key)"
          '';
        }
        {
          sources = { inherit x; a.file = "/fixtures/alt2"; };
          check = checkFlake { attr = "greeting"; expected = "dep+alt2"; } + ''
            test "$(readlink "$T"/x)" != "$(cat "$T".first)" || fail "store path unchanged"
          '';
        }
      ];
    }))
    # A materialized input is a writable copy, patched and with a rewritten
    # lock file, which gets made again only when what it derives from
    # changes, and becomes a link again when not materialized anymore.
    (s "materialize" (let
      x = patches: alt // {
        x.flake-input = {
          url = "/fixtures/top"; name = "dep"; inherit fetchOnTarget patches;
          materialize = true;
          inputs.inner.follows = "alt";
        };
      };
      hello = [ "/fixtures/patches/hello.patch" ];
    in {
      phases = [
        {
          sources = x hello;
          check = ''
            test ! -L "$T"/x || fail "x is a link"
            test -w "$T"/x/flake.nix || fail "flake.nix isn't writable"
            gc
            expect_eq greeting "$(nix_eval "$T"/x#greeting)" hello+alt
          '';
          mutate = ''
            echo local > "$T"/x/local
          '';
        }
        {
          sources = x hello;
          check = ''
            expect_eq local "$(cat "$T"/x/local)" local
          '';
        }
        {
          sources = x (hello ++ [ "/fixtures/patches/hello2.patch" ]);
          check = ''
            test ! -e "$T"/x/local || fail "local remains"
            gc
            expect_eq greeting "$(nix_eval "$T"/x#greeting)" hello2+alt
          '';
        }
        {
          sources = alt // {
            x.flake-input = { url = "/fixtures/top"; name = "dep"; inherit fetchOnTarget; };
          };
          check = checkFlake { attr = "greeting"; expected = "dep+inner"; } + ''
            test ! -e "$T"/.populate/derived || fail "derived remains"
          '';
        }
      ];
    }))
    # Roots follow the delivered input.
    (s "retarget" {
      phases = [
        {
          sources.x.flake-input = { url = "/fixtures/top"; name = "dep"; inherit fetchOnTarget; };
          check = ''
            expect_eq roots "$(ls "$T"/.populate/flake-inputs/x | wc -l)" 1
          '';
        }
        {
          sources.x.flake-input = { url = "/fixtures/top"; name = "sub"; inherit fetchOnTarget; };
          check = ''
            test ! -e "$T"/.populate/flake-inputs/x || fail "roots remain"
            test ! -e "$T"/.populate/flake-inputs || fail "empty roots directory remains"
          '' + checkFlake { attr = "who"; expected = "sub"; subdir = true; };
        }
      ];
    })
    # Pruning removes everything sources don't deliver anymore, including
    # garbage collector roots, and keeps everything else.
    (s "prune" (let
      sources = {
        a.file = "/fixtures/alt";
        b.flake = { url = "/fixtures/top"; inherit fetchOnTarget; };
        c.flake-input = { url = "/fixtures/top"; name = "dep"; inherit fetchOnTarget; };
        d.symlink = "a";
      };
    in {
      prepare = ''
        mkdir -p "$T"
        echo other > "$T"/other
      '';
      phases = [
        {
          inherit sources;
          check = ''
            test -e "$T"/.populate/flake-inputs/b || fail "roots of b missing"
            test -e "$T"/.populate/flake-inputs/c || fail "roots of c missing"
          '';
        }
        {
          # Without pruning, nothing gets removed.
          sources = { inherit (sources) a; };
          check = ''
            for name in b c d other .populate/flake-inputs/b .populate/flake-inputs/c; do
              test -e "$T"/$name || fail "$name removed"
            done
          '';
          # An upload an interrupted run left behind.
          mutate = ''
            mkdir -p "$T"/.populate/flake-uploads/c/tree
          '';
        }
        {
          # b changes its type, so its roots go, while b stays.
          sources = { inherit (sources) a; b.symlink = "a"; };
          prune = true;
          output = map
            (name: "pruning '${{
              local = "";
              remote = "${remoteHost}:";
              sudo = "deploy@${remoteHost}:";
            }.${targetKind}}/var/krops/prune-${targetKind}/${name}'...")
            [ "c" "d" "other" ];
          check = ''
            test -e "$T"/a/flake.nix || fail "a removed"
            expect_eq b "$(readlink "$T"/b)" a
            test -d "$T"/.populate || fail ".populate removed"
            for name in c d other .populate/flake-inputs .populate/flake-uploads; do
              test ! -e "$T"/$name || fail "$name not pruned"
            done
            if nix-store --gc --print-roots 2>/dev/null | grep -F "$T/"; then
              fail "garbage collector roots remain"
            fi
          '';
        }
      ];
    }))
    (s "cycle" {
      phases = [{
        sources = {
          a.file = { path = "/fixtures/alt"; inputs.foo.follows = "b"; };
          b.file = { path = "/fixtures/alt"; inputs.foo.follows = "a"; };
        };
        expect = "eval-error";
        control = {
          a.file = { path = "/fixtures/alt"; inputs.foo.follows = "b"; };
          b.file = "/fixtures/alt";
        };
      }];
    })
    (s "self" {
      phases = [{
        sources.a.file = { path = "/fixtures/alt"; inputs.foo.follows = "a"; };
        expect = "eval-error";
        control = alt // {
          a.file = { path = "/fixtures/alt"; inputs.foo.follows = "alt"; };
        };
      }];
    })
    (s "missing" {
      phases = [{
        sources.a.file = { path = "/fixtures/alt"; inputs.foo.follows = "nope"; };
        expect = "eval-error";
        control = {
          a.file = { path = "/fixtures/alt"; inputs.foo.follows = "nope"; };
          nope.file = "/fixtures/alt";
        };
      }];
    })
    (s "noflake" {
      phases = [{
        sources = alt // {
          x.file = { path = "/fixtures/noflake"; inputs.foo.follows = "alt"; };
        };
        expect.fail = "error: source x draws flake inputs from other sources, but contains no flake.nix";
      }];
    })
    (s "noinput" {
      phases = [{
        sources.x.flake-input = { url = "/fixtures/top"; name = "nope"; inherit fetchOnTarget; };
        expect.fail = "error: flake /fixtures/top has no input nope";
      }];
    })
    # An input locked to a path the target doesn't have.
    (s "gone" {
      phases = [{
        sources.x.flake = { url = "/fixtures/usegone"; fetchOnTarget = true; };
        expect.fail = "error: flake /fixtures/usegone: input gone refers to /fixtures/gone, which does not exist on the target";
      }];
    })
  ]) targetKinds;

  # Edge cases of the flake source types and of generated flakes: unusual lock
  # files, references, and changes between deploys.
  edge-cases = concatMap (targetKind: let
    s = name: args: scenario ({
      name = "${name}-${targetKind}";
      inherit targetKind;
      isolate = true;
    } // args);
    copying = targetKind != "sudo";
    fetchOnTarget = !copying;
    roots = n: ''
      expect_eq roots "$(ls "$T"/.populate/flake-inputs/x 2>/dev/null | wc -l)" ${toString n}
    '';
    # A scenario for each way of drawing inputs, which f gets as mode, along
    # with draw, which adds inputs drawn that way to a source's options, and
    # flake, which gives the flake to evaluate for a source.
    modes = name: f: map
      (mode: s "${name}-${mode}" (f {
        draw = drawInputs mode;
        flake = n:
          if mode == "generated" then ''"$T"/.populate/flakes/${n}'' else ''"$T"/${n}'';
        inherit mode;
      }))
      [ "rewrite" "generated" ];
  in lib.flatten [
    # The registry entry kropsremote, which fixtures.sh adds on the deploying
    # machine, points at ${url}/remote.tar.gz.  The deploying machine has no
    # global registry, which it couldn't download.
    (s "indirect" {
      phases = twice {
        sources.x.flake = { url = "kropsremote"; inherit fetchOnTarget; };
        check = checkFlake { attr = "msg"; expected = "remote:dep+inner"; };
      };
    })
    (s "remote-subdir" {
      phases = twice {
        sources.x.flake = { url = "${url}/mono.tar.gz?dir=sub"; inherit fetchOnTarget; };
        check = checkFlake { attr = "who"; expected = "sub"; subdir = true; };
      };
    })
    (modes "subdir-inputs" ({ draw, mode, ... }: {
      phases = twice {
        sources = alt // {
          x.flake = {
            url = "git+file:/fixtures/monoin?dir=sub"; inherit fetchOnTarget;
          } // draw { dep.follows = "alt"; };
        };
        check = checkFlake {
          attr = "msg"; expected = "monoin:alt"; subdir = true;
          generated = mode == "generated";
        };
      };
    }))
    (s "dirty" {
      phases = twice {
        sources.x.flake = { url = "/fixtures/dirty"; inherit fetchOnTarget; };
        check = checkFlake { attr = "msg"; expected = "dirty:dep+inner,sub"; } + ''
          test ! -e "$T"/x/untracked || fail "untracked file delivered"
        '';
      };
    })
    (s "unlocked" {
      phases = [{
        sources.x.flake = { url = "/fixtures/unlocked"; inherit fetchOnTarget; };
        expect.fail = "requires lock file changes";
      }];
    })
    (s "notdir" {
      phases = [{
        sources = {
          x.file = { path = "/fixtures/filesrc"; inputs.dep.follows = "p"; };
          p.pipe = "/fixtures/pipe";
        };
        expect.fail = "error: source p is not a directory";
      }];
    })
    (s "noinput-nested" {
      phases = [{
        sources.x.flake-input = { url = "/fixtures/top"; name = "dep/nope"; inherit fetchOnTarget; };
        expect.fail = "error: flake /fixtures/top has no input dep/nope";
      }];
    })
    (s "shared" {
      phases = twice {
        sources = {
          x.flake = { url = "/fixtures/top"; inherit fetchOnTarget; };
          dep.flake-input = { url = "/fixtures/top"; name = "dep"; inherit fetchOnTarget; };
          sub.flake-input = { url = "/fixtures/top"; name = "sub"; fetchOnTarget = true; };
        };
        check = checkFlake { attr = "msg"; expected = "top:dep+inner,sub"; } + ''
          expect_eq dep "$(nix_eval "$T"/dep#greeting)" dep+inner
          expect_eq sub "$(nix_eval "$T"/sub#who)" sub
        '';
      };
    })
    (s "follows-empty" {
      phases = twice {
        sources.x.flake = { url = "/fixtures/nofollow"; fetchOnTarget = true; };
        check = checkFlake { attr = "msg"; expected = "nofollow"; };
      };
    })
    (s "follows-cycle" {
      phases = twice {
        sources.x.flake = { url = "/fixtures/cyc"; fetchOnTarget = true; };
        check = checkFlake { attr = "msg"; expected = "cyc:cyca,cycb"; };
      };
    })
    # Names resolve through the parent's lock file, so dep/inner is the
    # parent's inner, which dep's inner follows.
    (s "follows-name" {
      phases = twice {
        sources.x.flake-input = { url = "/fixtures/follow"; name = "dep/inner"; inherit fetchOnTarget; };
        check = checkFlake { attr = "who"; expected = "inner2"; };
      };
    })
    # The delivered input comes with the inputs its own lock file pins, which
    # evaluating it needs, not with the parent's inner, which it follows there.
    (s "follows-closure" {
      phases = twice {
        sources.x.flake-input = { url = "/fixtures/follow"; name = "dep"; inherit fetchOnTarget; };
        check = checkFlake { attr = "greeting"; expected = "dep+inner"; } + roots 1;
      };
    })
    (s "relative-input" {
      phases = twice {
        sources.x.flake = { url = "/fixtures/rel"; fetchOnTarget = true; };
        check = checkFlake { attr = "msg"; expected = "rel:lib"; };
      };
    })
    # The target can't fetch an input of the flake.  The deploying machine
    # fetched it when locking, so its fetcher cache has to go.
    (s "fetch-failure" {
      prepareDeployer = ''
        rm -fR /root/.cache/nix
      '';
      phases = [{
        sources.x.flake = { url = "/fixtures/broken"; fetchOnTarget = true; };
        expect.fail = "vanishing.tar.gz";
      }];
    })
    # The delivered input itself is locked to a path the target lacks.
    (s "gone-input" {
      phases = [{
        sources.x.flake-input = { url = "/fixtures/usegone"; name = "gone"; fetchOnTarget = true; };
        expect.fail = "input gone refers to /fixtures/gone, which does not exist on the target";
      }];
    })
    # An input that gets drawn from a source isn't needed on the target, with
    # all it pins.
    (modes "overridden-roots" ({ draw, mode, ... }: {
      # What gets delivered doesn't depend on how inputs get drawn.
      exhaustive = mode == "generated";
      phases = twice {
        sources = alt // {
          x.flake-input = {
            url = "/fixtures/top"; name = "dep"; inherit fetchOnTarget;
          } // draw { inner.follows = "alt"; };
        };
        check = checkFlake {
          attr = "greeting"; expected = "dep+alt";
          generated = mode == "generated";
        } + roots 0;
      };
    }))
    # The input's own lock file pins something unreachable, which gets drawn
    # from a source anyway.
    (modes "own-lock-unreachable" ({ draw, mode, ... }: {
      # What gets delivered doesn't depend on how inputs get drawn.
      exhaustive = mode == "generated";
      prepareDeployer = ''
        rm -fR /root/.cache/nix
      '';
      phases = twice {
        sources = alt // {
          x.flake-input = {
            url = "/fixtures/usepinned"; name = "dep"; inherit fetchOnTarget;
          } // draw { inner.follows = "alt"; };
        };
        check = checkFlake {
          attr = "greeting"; expected = "pinned+alt";
          generated = mode == "generated";
        };
      };
    }))
    # The input's own lock file pins something unreachable, or lacks an input
    # its flake.nix has.  That fails, unless the input isn't required to come
    # with its inputs.
    (s "own-lock-broken" (let
      x = url: requireInputs: {
        x.flake-input = { inherit url; name = "dep"; inherit fetchOnTarget requireInputs; };
      };
      delivered = ''
        test -e "$T"/x/flake.nix || fail "input not delivered"
      '';
    in {
      prepareDeployer = ''
        rm -fR /root/.cache/nix
      '';
      phases = [
        {
          sources = x "/fixtures/usepinned" true;
          expect.fail = "error: source x: the inputs its own lock file pins can't be delivered.  Set its requireInputs to false to deliver it anyway.";
        }
        {
          sources = x "/fixtures/usepinned" false;
          check = delivered + roots 0;
        }
        {
          sources = x "/fixtures/usestale" true;
          expect.fail = "error: source x: the inputs its own lock file pins can't be delivered.  Set its requireInputs to false to deliver it anyway.";
        }
        {
          sources = x "/fixtures/usestale" false;
          check = delivered + roots 2;
        }
        {
          sources = x "/fixtures/usestale" false;
          check = delivered + roots 2;
        }
      ];
    }))
    # Redeploying an unchanged input while where it comes from is
    # unreachable and the fetcher caches are gone: the store has it.
    (s "offline-redeploy" (let
      sources.x.flake-input = { url = "/fixtures/offline"; name = "gap"; inherit fetchOnTarget; };
      check = checkFlake { attr = "who"; expected = "gap"; };
    in {
      prepareDeployer = ''
        if test -e /fixtures/www/gap.tar.gz.off; then
          mv /fixtures/www/gap.tar.gz.off /fixtures/www/gap.tar.gz
        fi
      '';
      phases = [
        {
          inherit sources check;
          mutate = ''
            rm -fR /root/.cache/nix
          '';
          mutateDeployer = ''
            rm -fR /root/.cache/nix
            mv /fixtures/www/gap.tar.gz /fixtures/www/gap.tar.gz.off
          '';
        }
        {
          inherit sources check;
          mutateDeployer = ''
            mv /fixtures/www/gap.tar.gz.off /fixtures/www/gap.tar.gz
          '';
        }
      ];
    }))
    (s "flake-to-file" {
      phases = [
        {
          sources.x.flake = { url = "/fixtures/top"; inherit fetchOnTarget; };
          check = roots 3;
          mutate = ''
            readlink "$T"/x > "$T"/old
          '';
        }
        {
          sources.x.file = "/fixtures/alt";
          check = ''
            test ! -L "$T"/x || fail "x is still a link to $(readlink "$T"/x)"
            test -e "$T"/x/flake.nix || fail "flake.nix missing"
            nix-store --verify-path "$(cat "$T"/old)" || fail "store path changed"
          '' + roots 0;
        }
      ];
    })
    (s "symlink-to-flake" {
      phases = [
        {
          sources = alt // { x.symlink = "alt"; };
          check = ''
            expect_eq link "$(readlink "$T"/x)" alt
          '';
        }
        {
          sources = alt // { x.flake = { url = "/fixtures/top"; inherit fetchOnTarget; }; };
          check = checkFlake { attr = "msg"; expected = "top:dep+inner,sub"; } + ''
            test -e "$T"/alt/flake.nix || fail "alt changed"
          '';
        }
      ];
    })
    # The ssh master stops, after failing as well as after succeeding.
    (s "ssh-master" (let
      checkDeployer = ''
        for i in 1 2 3 4 5 6 7 8 9 10; do
          if ! pgrep -f 'ssh: .*/populate\..*\[mux\]' >/dev/null; then
            exit 0
          fi
          sleep 0.5
        done
        fail "ssh master remains"
      '';
    in {
      phases = [
        {
          sources.x.flake-input = { url = "/fixtures/top"; name = "nope"; inherit fetchOnTarget; };
          expect.fail = "error: flake /fixtures/top has no input nope";
          inherit checkDeployer;
        }
        {
          sources = alt;
          inherit checkDeployer;
        }
      ];
    }))
    # Pruning entries whose names a shell's read would strip or split.
    (s "prune-names" {
      prepare = ''
        mkdir -p "$T/ lead" "$T/trail " "$T/$(printf 'new\nline')" "$T/axb" "$T/[b]"
      '';
      phases = [{
        sources = alt;
        prune = true;
        check = ''
          # In the C locale, ls sorts by bytes, so . comes first.
          expect_eq entries "$(LC_ALL=C ls -A "$T" | tr '\n' ' ')" '.populate alt '
        '';
      }];
    })
    # Misspelt input names draw nothing, so they fail before anything
    # changes: of the source's flake, and below an input drawn from a source.
    (modes "inputs-typo" ({ draw, ... }: {
      phases = [
        {
          sources = alt // {
            x.flake-input = {
              url = "/fixtures/top"; name = "dep"; inherit fetchOnTarget;
            } // draw { innr.follows = "alt"; };
          };
          expect.fail = "error: source x draws input innr from source alt, but its flake has no input innr";
        }
        {
          sources = {
            x.flake = {
              url = "/fixtures/top"; inherit fetchOnTarget;
            } // draw { dep = { follows = "b"; inputs.qq.follows = "c2"; }; };
            b.file = "/fixtures/two";
            c2.file = "/fixtures/c2";
          };
          expect.fail = "error: source x draws input dep/qq from source c2, but the flake of source b has no input qq";
        }
      ];
    }))
    # A signal ending populate leaves neither the ssh master nor the
    # temporary directory.
    (s "interrupt" {
      prepareDeployer = ''
        find "''${TMPDIR:-/tmp}" -maxdepth 1 -name 'populate.*' -exec rm -fR {} +
      '';
      phases = [{
        sources.x.pipe = "/fixtures/pipe-slow";
        interrupt = 3;
        checkDeployer = ''
          for i in 1 2 3 4 5 6 7 8 9 10; do
            if ! pgrep -f 'ssh: .*/populate\..*\[mux\]' >/dev/null; then
              break
            fi
            sleep 0.5
          done
          ! pgrep -f 'ssh: .*/populate\..*\[mux\]' >/dev/null ||
            fail "ssh master remains"
          expect_eq "temporary directories" \
              "$(find "''${TMPDIR:-/tmp}" -maxdepth 1 -name 'populate.*')" ""
        '';
      }];
    })
    # An input of an input drawn from a source that draws inputs itself
    # gets drawn from another source.
    (modes "override" ({ draw, flake, ... }: {
      # Drawing inputs happens on the target alike for every kind of target.
      exhaustive = targetKind != "local";
      phases = twice {
        sources = {
          x.flake = {
            url = "/fixtures/top"; inherit fetchOnTarget;
          } // draw { dep = { follows = "b"; inputs.q.follows = "c2"; }; };
          b.file = { path = "/fixtures/two"; } // draw { p.follows = "c1"; };
          c1.file = "/fixtures/c1";
          c2.file = "/fixtures/c2";
        };
        check = ''
          expect_eq msg "$(nix_eval_online ${flake "x"}#msg)" top:two:c1+c2,sub
        '';
      };
    }))
    # The same one level deeper: the input gets drawn from a source below
    # an input that the source in between draws from a source itself.
    (modes "override-deep" ({ draw, flake, ... }: {
      # Drawing inputs happens on the target alike for every kind of target.
      exhaustive = targetKind != "local";
      phases = twice {
        sources = {
          x.flake = {
            url = "/fixtures/top"; inherit fetchOnTarget;
          } // draw { dep = { follows = "b"; inputs.p.inputs.z.follows = "c2"; }; };
          b.file = { path = "/fixtures/two"; } // draw { p.follows = "c3"; };
          c2.file = "/fixtures/c2";
          c3.file = "/fixtures/c3";
        };
        check = ''
          expect_eq msg "$(nix_eval_online ${flake "x"}#msg)" 'top:two:c3(c2)+inner,sub'
        '';
      };
    }))
    # A source with a rewritten lock file draws an input from a source with
    # a generated flake, and an input below it from another source.
    (s "override-mixed" {
      # Drawing inputs happens on the target alike for every kind of target.
      exhaustive = targetKind != "local";
      phases = twice {
        sources = {
          x.flake = {
            url = "/fixtures/top"; inherit fetchOnTarget;
            inputs.dep = { follows = "b"; inputs.q.follows = "c2"; };
          };
          b.file = {
            path = "/fixtures/two";
            rewriteLock = false;
            inputs.p.follows = "c1";
          };
          c1.file = "/fixtures/c1";
          c2.file = "/fixtures/c2";
        };
        check = ''
          expect_eq msg "$(nix_eval_online "$T"/x#msg)" top:two:c1+c2,sub
        '';
      };
    })
    (modes "nonflake-input" ({ draw, flake, ... }: {
      # Drawing inputs happens on the target alike for every kind of target.
      exhaustive = targetKind != "local";
      phases = twice {
        sources = {
          x.file = { path = "/fixtures/usedata"; } // draw { data.follows = "data"; };
          data.file = "/fixtures/data";
        };
        check = ''
          expect_eq msg "$(nix_eval ${flake "x"}#msg)" data:hello
        '';
      };
    }))
    # The target directory in a Git work tree.
    (modes "gitdir" ({ draw, flake, ... }: {
      prepare = ''
        mkdir -p "$T"
        git -C "$T" init -q
      '';
      phases = twice {
        sources = alt // {
          x.file = { path = "/fixtures/filesrc"; } // draw { dep.follows = "alt"; };
        };
        check = ''
          # Not just the path, which Nix takes for the enclosing work tree.
          expect_eq msg "$(nix_eval_online path:${flake "x"}#msg)" top:alt,sub
        '';
      };
    }))
    # Output of the same length, which rsync's quick check doesn't notice.
    (s "pipe-change" {
      prepareDeployer = ''
        echo piped > /fixtures/pipe2-data
      '';
      phases = [
        {
          sources.x.pipe = "/fixtures/pipe2";
          check = ''
            expect_eq x "$(cat "$T"/x)" piped
          '';
          mutateDeployer = ''
            echo PIPED > /fixtures/pipe2-data
          '';
        }
        {
          sources.x.pipe = "/fixtures/pipe2";
          check = ''
            expect_eq x "$(cat "$T"/x)" PIPED
          '';
          mutateDeployer = ''
            echo piped > /fixtures/pipe2-data
          '';
        }
      ];
    })
    # Source names that aren't input names, or that Nix has another use
    # for, both of sources inputs get drawn from and of sources drawing them.
    (modes "source-name" ({ draw, flake, ... }: let
      x = from: { path = "/fixtures/filesrc"; } // draw { dep.follows = from; };
    in {
      # Drawing inputs happens on the target alike for every kind of target.
      exhaustive = targetKind != "local";
      phases = twice {
        sources = {
          "alt-1.0".file = "/fixtures/alt";
          self.file = "/fixtures/alt";
          x.file = x "alt-1.0";
          y.file = x "self";
          "a.b_c-d".file = x "self";
        };
        check = ''
          expect_eq x "$(nix_eval_online ${flake "x"}#msg)" top:alt,sub
          expect_eq y "$(nix_eval_online ${flake "y"}#msg)" top:alt,sub
          expect_eq a.b_c-d "$(nix_eval_online ${flake "a.b_c-d"}#msg)" top:alt,sub
        '';
      };
    }))
    # An upload an interrupted run left behind.
    (s "upload-leftover" {
      phases = [
        {
          sources.x.flake = { url = "/fixtures/top"; fetchOnTarget = true; };
          check = checkFlake { attr = "msg"; expected = "top:dep+inner,sub"; };
          mutate = ''
            mkdir -p "$T"/.populate/flake-uploads/x/tree
            echo half > "$T"/.populate/flake-uploads/x/tree/half
          '';
        }
        {
          sources.x.flake = { url = "/fixtures/top"; fetchOnTarget = true; };
          check = checkFlake { attr = "msg"; expected = "top:dep+inner,sub"; };
        }
      ];
    })
  ] ++ lib.optional (targetKind == "local")
    # The target has the path the input is locked to.
    (s "uselocal" {
      phases = twice {
        sources.x.flake = { url = "/fixtures/uselocal"; fetchOnTarget = true; };
        check = checkFlake { attr = "msg"; expected = "uselocal:alt"; };
      };
    })
  ) targetKinds;


  # Populate replaces and removes things in the target directory.  These
  # scenarios check that it doesn't anywhere else: names and paths that lead
  # out of the target directory don't evaluate, and symlinks in it get
  # replaced or refused instead of followed.  The canaries, which every phase
  # of every scenario checks, tell if something outside changed; these
  # scenarios point links at them.
  safety = concatMap (targetKind: let
    s = name: args: scenario ({
      name = "${name}-${targetKind}";
      inherit targetKind;
    } // args);
    copying = targetKind != "sudo";
    fetchOnTarget = !copying;
    outside = "/var/krops-outside";
    hello = [ "/fixtures/patches/hello.patch" ];
    # Sources that use every kind of state populate keeps: x a copy with
    # patches, y garbage collector roots and, where the flake gets uploaded,
    # an upload, and z a generated flake.
    stateful = alt // {
      x.flake-input = {
        url = "/fixtures/top"; name = "dep"; inherit fetchOnTarget;
        patches = hello;
        inputs.inner.follows = "alt";
      };
      y.flake = { url = "/fixtures/top"; inherit fetchOnTarget; };
      z.file = {
        path = "/fixtures/filesrc";
        rewriteLock = false;
        inputs.dep.follows = "alt";
      };
    };
    # A source deployed where a symlink to something outside is.  The link
    # gets replaced, never followed.
    link = type: { sources, to, check, says ? true }: let
      phase = {
        inherit sources;
        check = ''
          case $(readlink "$T"/x || :) in
            ${outside}/*) fail "x still links outside" ;;
          esac
        '' + check;
      };
    in s "link-${type}" {
      isolate = true;
      prepare = ''
        mkdir -p "$T"
        ln -s ${outside}/${to} "$T"/x
      '';
      phases = [
        (phase // {
          output = optional says
            "replacing symlink /var/krops/link-${type}-${targetKind}/x, which points to ${outside}/${to}";
        })
        phase
      ];
    };
    # Something of populate's state replaced by a symlink to outside between
    # two deploys.  The second one refuses to use it.
    state = name: {
      entry, backup ? false,
      message ? "/${entry} is a symlink, but populate needs a directory of its own there",
    }: s "state-${name}" {
      isolate = true;
      phases = [
        {
          sources = stateful;
          inherit backup;
          mutate = ''
            rm -fR "$T"/${entry}
            mkdir -p "$(dirname "$T"/${entry})"
            ln -s ${outside}/dir "$T"/${entry}
          '';
        }
        {
          sources = stateful;
          inherit backup;
          expect.fail = message;
        }
      ];
    };
  in lib.flatten [
    (link "file" {
      sources.x.file = "/fixtures/alt";
      to = "dir";
      check = ''
        test -e "$T"/x/flake.nix || fail "flake.nix missing"
      '';
    })
    # What rsync logs about each item: what changed, and its size.
    (s "rsync-log" {
      phases = [{
        sources.x.file = "/fixtures/alt";
        output = [ "f+++++++++ flake.nix " "/53" ];
      }];
    })
    # The link points at a Git work tree, which resetting and cleaning would
    # change.
    (link "git" {
      sources.x.git = { url = gitUrl; ref = gitHead; };
      to = "repo";
      check = ''
        expect_eq HEAD "$(git -C "$T"/x rev-parse HEAD)" ${gitHead}
      '';
    })
    (link "pass" {
      sources.x.pass = { dir = "/fixtures/pass"; name = "x"; };
      to = "dir";
      check = ''
        expect_eq a "$(cat "$T"/x/a)" secret-a
      '';
    })
    (link "passage" {
      sources.x.passage = {
        dir = "/fixtures/passage/store/x";
        identities_file = "/fixtures/passage/identities";
      };
      to = "dir";
      check = ''
        expect_eq a "$(cat "$T"/x/a)" secret-a
      '';
    })
    (link "pipe" {
      sources.x.pipe = "/fixtures/pipe";
      to = "file";
      check = ''
        expect_eq x "$(cat "$T"/x)" piped
      '';
    })
    (link "derivation" {
      sources.x.derivation = ''
        derivation {
          name = "krops-test";
          system = builtins.currentSystem;
          builder = "/bin/sh";
          args = [ "-c" "echo built > $out" ];
        }
      '';
      to = "file";
      check = ''
        expect_eq x "$(cat "$T"/x)" built
      '';
    })
    (link "symlink" {
      sources = alt // { x.symlink = "alt"; };
      to = "dir";
      says = false;
      check = ''
        expect_eq link "$(readlink "$T"/x)" alt
      '';
    })
    (link "flake" {
      sources.x.flake = { url = "/fixtures/top"; inherit fetchOnTarget; };
      to = "dir";
      check = checkFlake { attr = "msg"; expected = "top:dep+inner,sub"; };
    })
    (link "flake-materialized" {
      sources.x.flake = {
        url = "/fixtures/top"; inherit fetchOnTarget;
        materialize = true;
      };
      to = "dir";
      check = checkFlake {
        attr = "msg"; expected = "top:dep+inner,sub"; materialized = true;
      };
    })
    (link "flake-input-patched" {
      sources.x.flake-input = {
        url = "/fixtures/top"; name = "dep"; inherit fetchOnTarget;
        patches = hello;
      };
      to = "dir";
      check = checkFlake { attr = "greeting"; expected = "hello+inner"; };
    })
    # Symlinks to outside in what a source replaces: rsync and Git remove
    # them, and so does replacing a directory by a link.
    (s "inner-links" (let
      prepare = ''
        for name in a b c; do
          mkdir -p "$T"/$name
          ln -s ${outside}/dir "$T"/$name/keep
          ln -s ${outside}/dir "$T"/$name/stale
          ln -s ${outside}/repo/.git "$T"/$name/.git
        done
        # A work tree whose repository is elsewhere.
        mkdir -p "$T"/d
        echo "gitdir: ${outside}/repo/.git" > "$T"/d/.git
      '';
    in {
      isolate = true;
      inherit prepare;
      phases = twice {
        sources = {
          a.file = "/fixtures/filesrc";
          b.git = { url = gitUrl; ref = gitHead; };
          c.flake = { url = "/fixtures/top"; inherit fetchOnTarget; };
          d.git = { url = gitUrl; ref = gitHead; };
        };
        check = ''
          expect_eq keep "$(cat "$T"/a/keep)" keep
          test ! -L "$T"/a/stale || fail "a/stale remains"
          expect_eq HEAD "$(git -C "$T"/b rev-parse HEAD)" ${gitHead}
          test ! -L "$T"/b/.git || fail "b/.git remains a link"
          test ! -L "$T"/b/stale || fail "b/stale remains"
          expect_eq HEAD "$(git -C "$T"/d rev-parse HEAD)" ${gitHead}
          test -d "$T"/d/.git || fail "d/.git isn't a directory"
          expect_eq "store directory" "$(dirname "$(readlink "$T"/c)")" /nix/store
        '';
      };
    }))
    (state "sentinel" {
      entry = ".populate";
      message = "error: sentinel file is a symlink";
    })
    (state "backup" { entry = ".populate/backup"; backup = true; })
    (map
      (entry: state (lib.replaceStrings ["/"] ["-"] entry) {
        entry = ".populate/${entry}";
      })
      [
        "derived" "flake-inputs" "flake-uploads" "flakes" "patches"
        "derived/x" "patches/x" "flake-inputs/y" "flake-uploads/y" "flakes/z"
      ])
    # Symlinks to outside among what populate removes: leftovers of
    # interrupted runs, state of sources that are gone, and, when pruning,
    # entries of the target directory.  They get removed as links.  So do
    # hard links to a read-only file outside, whose mode stays.
    (s "leftovers" {
      isolate = true;
      prepare = ''
        mkdir -p "$T"/hard
        ln -s ${outside}/dir "$T"/other
        ln -s ${outside}/repo "$T"/repo
        ln ${outside}/dir/sub/file "$T"/hard/link
        ln ${outside}/dir/sub/file "$T"/hardlink
      '';
      phases = [
        {
          sources = stateful;
          mutate = ''
            ln -s ${outside}/dir "$T"/.populate/derived/x/work
            ln -s ${outside}/dir "$T"/.populate/derived/gone
            ln -s ${outside}/dir "$T"/.populate/flakes/gone
            ln -s ${outside}/dir "$T"/.populate/patches/gone
            ln -s ${outside}/dir "$T"/.populate/flake-inputs/gone
            mkdir -p "$T"/.populate/flake-uploads
            ln -s ${outside}/dir "$T"/.populate/flake-uploads/gone
          '';
        }
        {
          sources = stateful;
          check = ''
            for name in derived/x/work derived/gone flakes/gone patches/gone; do
              test ! -L "$T"/.populate/$name || fail "$name remains"
            done
            for name in other repo .populate/flake-inputs/gone .populate/flake-uploads/gone; do
              test -L "$T"/$name || fail "$name removed without pruning"
            done
          '';
        }
        {
          sources = stateful;
          prune = true;
          check = ''
            for name in other repo hard hardlink .populate/flake-inputs/gone .populate/flake-uploads; do
              test ! -L "$T"/$name && test ! -e "$T"/$name || fail "$name not pruned"
            done
          '';
        }
      ];
    })
    # A target path with characters that mean something to shells and in
    # URLs.
    (s "odd-target" (let
      targetPath = "/var/krops/odd-target-${targetKind}/a b*c?d#e%f";
    in {
      isolate = true;
      phases = twice {
        sources = stateful // {
          g.git = { url = gitUrl; ref = gitHead; };
          p.pipe = "/fixtures/pipe";
        };
        inherit targetPath;
        prune = true;
        check = ''
          D=${lib.escapeShellArg targetPath}
          test -e "$D"/alt/flake.nix || fail "alt missing"
          expect_eq HEAD "$(git -C "$D"/g rev-parse HEAD)" ${gitHead}
          expect_eq p "$(cat "$D"/p)" piped
          expect_eq entries "$(ls "$T")" 'a b*c?d#e%f'
          gc
          expect_eq greeting "$(nix_eval "$(readlink -f "$D"/x)"#greeting)" hello+alt
          expect_eq msg "$(nix_eval "$(readlink -f "$D"/y)"#msg)" top:dep+inner,sub
        '';
      };
    }))
    # The target directory itself may be a symlink: what it points to is the
    # target directory then.
    (s "linked-target" {
      isolate = true;
      prepare = ''
        rm -fR "$T"-real
        mkdir "$T"-real
        ln -s "$(basename "$T")"-real "$T"
      '';
      phases = twice {
        sources = stateful;
        check = ''
          test -L "$T" || fail "the target directory isn't a link anymore"
          test -e "$T"-real/alt/flake.nix || fail "alt missing"
          gc
          expect_eq greeting "$(nix_eval "$(readlink -f "$T"/x)"#greeting)" hello+alt
          expect_eq msg "$(nix_eval "$(readlink -f "$T"/y)"#msg)" top:dep+inner,sub
          expect_eq msg "$(nix_eval_online "path:$(readlink -f "$T"/.populate/flakes/z)#msg")" top:alt,sub
        '';
      };
    })
    # Git work trees whose .git directory names places elsewhere, or a
    # command: a work tree elsewhere, a configuration file elsewhere, another
    # repository, and a command run when Git checks for changes.  Populate
    # refuses them, telling why, and replaces them by fresh clones with
    # reclone.  A hook doesn't run.
    (s "git-foreign" (let
      elsewhere = "/var/krops-elsewhere";
      git = name: reclone: {
        ${name}.git = { url = gitUrl; ref = gitHead; inherit reclone; };
      };
      untouched = ''
        cmp -s ${elsewhere}/config ${elsewhere}/config.orig ||
          fail "what b/.git/config links to changed"
        test ! -e ${elsewhere}/ran || fail "a command in a .git directory ran"
      '';
      refused = name: message: {
        sources = git name false;
        expect.fail = "error: populate doesn't use the Git work tree /var/krops/git-foreign-${targetKind}/${name}, because ${message}.  Fix that, remove the work tree, or set the source's reclone to true to replace it by a fresh clone.";
      };
    in {
      isolate = true;
      prepare = ''
        rm -fR ${elsewhere}
        mkdir -p ${elsewhere} "$T"
        for name in a b c d e; do
          git clone -q ${gitUrl} "$T"/$name
          git -C "$T"/$name checkout -q ${gitFirst}
        done
        git -C "$T"/a config core.worktree ${outside}/dir
        mv "$T"/b/.git/config ${elsewhere}/config
        ln -s ${elsewhere}/config "$T"/b/.git/config
        cp -p ${elsewhere}/config ${elsewhere}/config.orig
        printf '#! /bin/sh\ntouch ${elsewhere}/ran\n' > "$T"/c/.git/hooks/reference-transaction
        chmod +x "$T"/c/.git/hooks/reference-transaction
        echo ${outside}/repo/.git > "$T"/d/.git/commondir
        git -C "$T"/e config core.fsmonitor "touch ${elsewhere}/ran"
      '';
      phases = [
        (refused "a" "/var/krops/git-foreign-${targetKind}/a/.git/config sets core.worktree to ${outside}/dir")
        (refused "b" "/var/krops/git-foreign-${targetKind}/b/.git contains symlinks: /var/krops/git-foreign-${targetKind}/b/.git/config")
        {
          sources = git "c" false;
          check = untouched + ''
            expect_eq "c HEAD" "$(git -C "$T"/c rev-parse HEAD)" ${gitHead}
          '';
        }
        (refused "d" "/var/krops/git-foreign-${targetKind}/d/.git/commondir names another repository")
        (refused "e" "/var/krops/git-foreign-${targetKind}/e/.git/config sets core.fsmonitor, which neither git clone nor populate does")
        {
          sources = git "a" true // git "b" true // git "c" true // git "d" true // git "e" true;
          output = map
            (name: "replacing the Git work tree /var/krops/git-foreign-${targetKind}/${name}, because")
            [ "a" "b" "d" "e" ];
          check = untouched + ''
            for name in a b c d e; do
              expect_eq "$name HEAD" "$(git -C "$T"/$name rev-parse HEAD)" ${gitHead}
              test -e "$T"/$name/two || fail "$name/two missing"
            done
          '';
        }
      ];
    }))
    # A file in populate's state replaced by a symlink to a file outside.
    (s "state-key" (let
      sources.x.flake-input = {
        url = "/fixtures/top"; name = "dep"; inherit fetchOnTarget;
        patches = hello;
      };
    in {
      isolate = true;
      phases = [
        {
          inherit sources;
          mutate = ''
            rm "$T"/.populate/derived/x/key
            ln -s ${outside}/file "$T"/.populate/derived/x/key
          '';
        }
        {
          inherit sources;
          check = checkFlake { attr = "greeting"; expected = "hello+inner"; };
        }
      ];
    }))
    # Stale state that contains a hard link to a read-only file outside,
    # whose mode stays.
    (s "state-hard-link" (let
      sources.x.flake-input = {
        url = "/fixtures/top"; name = "dep"; inherit fetchOnTarget;
        patches = hello;
      };
    in {
      isolate = true;
      phases = [
        {
          inherit sources;
          mutate = ''
            mkdir -p "$T"/.populate/derived/gone "$T"/.populate/derived/x/work
            ln ${outside}/dir/sub/file "$T"/.populate/derived/gone/file
            ln ${outside}/dir/sub/file "$T"/.populate/derived/x/work/file
          '';
        }
        {
          inherit sources;
          check = ''
            test ! -e "$T"/.populate/derived/gone || fail "gone remains"
          '';
        }
      ];
    }))
    # The source contains flake.lock.populate and a file like the temporary
    # copy of the lock file, symlinks to a file outside.
    (s "lock-temporary-link" {
      isolate = true;
      prepareDeployer = ''
        rm -fR /var/krops-src/lock-temporary-link
        mkdir -p /var/krops-src
        cp -R /fixtures/filesrc /var/krops-src/lock-temporary-link
        ln -s ${outside}/file /var/krops-src/lock-temporary-link/flake.lock.populate
        ln -s ${outside}/file /var/krops-src/lock-temporary-link/.flake.lock.XXXXXX
      '';
      phases = twice {
        sources = alt // {
          x.file = {
            path = "/var/krops-src/lock-temporary-link";
            inputs.dep.follows = "alt";
          };
        };
        check = ''
          expect_eq msg "$(nix_eval_online path:"$T"/x#msg)" top:alt,sub
        '';
      };
    })
    # A file in the target directory is a hard link to a read-only file
    # outside with the same contents, which rsync takes for unchanged, and
    # would fix the mode and time of in place.
    (s "rsync-hard-link" {
      isolate = true;
      prepareDeployer = ''
        rm -fR /var/krops-src/rsync-hard-link
        mkdir -p /var/krops-src/rsync-hard-link
        echo outside > /var/krops-src/rsync-hard-link/file
      '';
      prepare = ''
        mkdir -p "$T"/x
        ln ${outside}/dir/sub/file "$T"/x/file
      '';
      phases = twice {
        sources.x.file = {
          path = "/var/krops-src/rsync-hard-link";
          useChecksum = true;
        };
        check = ''
          expect_eq file "$(cat "$T"/x/file)" outside
          expect_eq links "$(stat -c %h "$T"/x/file)" 1
        '';
      };
    })
    (lib.optionals (targetKind == "local") [
      # Rewriting a lock file changes no other hard link to it.  The lock
      # file is like the source's, with its modification time, so rsync
      # leaves the link in place.  (The source is on the deploying machine,
      # so this only runs there.)
      (s "lock-hard-link" {
        prepare = ''
          mkdir -p "$T"
          cp -a /fixtures/filesrc "$T"/x
          cp -p "$T"/x/flake.lock "$T".lock
          ln -f "$T".lock "$T"/x/flake.lock
        '';
        phases = twice {
          sources = alt // {
            x.file = { path = "/fixtures/filesrc"; inputs.dep.follows = "alt"; };
          };
          check = ''
            cmp -s "$T".lock /fixtures/filesrc/flake.lock ||
              fail "the other hard link changed"
            expect_eq msg "$(nix_eval_online "$T"/x#msg)" top:alt,sub
          '';
        };
      })
      # Names that lead out of the target directory, to the directory itself,
      # or to populate's state.
      (s "names" {
        phases = map
          (name: {
            sources.${name}.file = "/fixtures/alt";
            expect = "eval-error";
            control = { ok.file = "/fixtures/alt"; };
          })
          [ "" "." ".." ".populate" "a/b" "../x" "/etc" "a\nb" "a b" "a*b" "a?b" "a+b" "a=b" "-a" ];
      })
      # Target paths that aren't absolute, that are the root directory, or
      # that resolve to another directory than they name.
      (s "paths" {
        phases = map
          (targetPath: {
            sources = alt;
            inherit targetPath;
            expect = "eval-error";
            controlTargetPath = "/var/krops/paths-local";
          })
          [ "" "/" "//" "/." "relative" "/var/krops/.." "/var/krops/../.." "/var/krops/a\nb" ];
      })
    ])
  ]) targetKinds;

}
