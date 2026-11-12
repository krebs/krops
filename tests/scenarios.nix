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
  # missing ones.
  scenario = {
    name, targetKind, node ? null, isolate ? false,
    prepare ? "", prepareDeployer ? null, phases,
  }: let
    path = "/var/krops/${name}";
    target = targets.${targetKind} path;
    vars = "T=${path}\n";
    # A phase expecting evaluation to fail has a control: sources that
    # differ only in what makes evaluation fail, or a function returning them
    # for the phase's sources, and that must evaluate.  So the phase doesn't
    # pass for failing for an unrelated reason, e.g. a misspelt option.
    phase = {
      sources, prune ? false, deploy ? null,
      expect ? "success", control ? null,
      check ? "", mutate ? null, checkDeployer ? null, mutateDeployer ? null,
    }: let
      command = sources: let
        args = {
          source = krops.evalSource [ sources ];
          inherit prune target;
          force = true;
        };
      in
        if deploy == null then populate args
        else writeDeploy "deploy" (args // { useNixOutputMonitor = false; } // deploy);
      evaluates = sources:
        (builtins.tryEval (builtins.seq (toString (command sources)) true)).success;
      script = text: if text == null then null else prelude + vars + text;
    in
      if expect == "eval-error" then
        if control == null then
          throw "scenario ${name}: expecting evaluation to fail needs a control"
        else if evaluates sources then
          throw "scenario ${name}: populate evaluates, but is expected to fail"
        else if !evaluates (if lib.isFunction control then control sources else control) then
          throw "scenario ${name}: the control doesn't evaluate either"
        else
          null
      else {
        populate = toString (command sources);
        expect = if expect == "success" then null else expect.fail;
        check = script check;
        mutate = script mutate;
        checkDeployer = script checkDeployer;
        mutateDeployer = script mutateDeployer;
      };
  in {
    inherit name isolate;
    node =
      if node != null then node
      else if targetKind == "local" then "deployer"
      else "target";
    prepare = prelude + vars + ''
      rm -fR "$T"
    '' + prepare;
    prepareDeployer =
      if prepareDeployer == null then null else prelude + vars + prepareDeployer;
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
        check = ''
          expect_eq keep "$(cat "$T"/x/keep)" keep
          ${if excluded then ''
            test ! -e "$T"/x/garbage || fail "garbage not excluded"
          '' else ''
            expect_eq garbage "$(cat "$T"/x/garbage)" garbage
          ''}
        '';
      }));
    }) [ null true false ]) targetKinds;

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
  });

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
  deploy = matrix "deploy" {
    flake = [ "none" "source" "rewrite" "generated" ];
    etcFlake = [ false true ];
    buildTarget = [ false true ];
  } (flags: ctx: let
    target = targets.${ctx.targetKind} ctx.path;
    buildTarget = targets.local "${ctx.path}-build";
    build = if flags.buildTarget then buildTarget else target;
    expected = [ "switch" ]
      ++ optionals flags.buildTarget [
        "--build-host" "${buildTarget.user}@${buildTarget.host}"
        "--target-host" "${target.user}@${target.host}"
      ]
      ++ optional (flags.buildTarget && target.sudo) "--use-remote-sudo"
      ++ {
        none = [];
        source = [ "--flake" "${build.path}/x" ];
        rewrite = [ "--flake" "${build.path}/x" ];
        # Generated flakes as path:, which an enclosing Git work tree doesn't
        # capture.
        generated = [ "--flake" "path:${build.path}/.populate/flakes/x" ];
      }.${flags.flake}
      ++ optional (flags.etcFlake && flags.flake == "none") "--no-flake";
  in
    # The local target can't have another build target.
    if flags.buildTarget && ctx.targetKind == "local" then null else {
      node = if flags.buildTarget then "deployer" else null;
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
        sources =
          if flags.flake == "none" then {
            x.file = "/fixtures/alt";
          } else alt // {
            x.flake = {
              url = "/fixtures/top";
              fetchOnTarget = ctx.targetKind == "sudo";
            } // drawInputs (if flags.flake == "source" then "none" else flags.flake) {
              dep.follows = "alt";
            };
          };
        deploy = {
          flake = if flags.flake == "none" then null else "x";
        } // optionalAttrs flags.buildTarget {
          inherit buildTarget;
        };
        check = ''
          expect_eq user "$(sed -n 1p /tmp/nixos-rebuild.log)" 0
          expect_eq NIX_PATH "$(sed -n 2p /tmp/nixos-rebuild.log)" ${build.path}
          expect_eq arguments "$(sed -n 3p /tmp/nixos-rebuild.log)" \
              ${lib.escapeShellArg (concatStringsSep " " expected)}
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
        }
        {
          # b changes its type, so its roots go, while b stays.
          sources = { inherit (sources) a; b.symlink = "a"; };
          prune = true;
          check = ''
            test -e "$T"/a/flake.nix || fail "a removed"
            expect_eq b "$(readlink "$T"/b)" a
            test -d "$T"/.populate || fail ".populate removed"
            for name in c d other .populate/flake-inputs; do
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
    # An input of an input drawn from a source that draws inputs itself
    # gets drawn from another source.
    (modes "override" ({ draw, flake, ... }: {
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
    (modes "nonflake-input" ({ draw, flake, ... }: {
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
    (modes "source-name" ({ draw, flake, ... }: {
      phases = twice {
        sources = {
          "alt-1.0".file = "/fixtures/alt";
          x.file = { path = "/fixtures/filesrc"; } // draw { dep.follows = "alt-1.0"; };
        };
        check = ''
          expect_eq msg "$(nix_eval_online ${flake "x"}#msg)" top:alt,sub
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

}
