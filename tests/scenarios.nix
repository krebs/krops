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
  # HEAD of /fixtures/gitsrc.
  gitHead,
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
  # subdirectory sub therein, and evaluates the attribute attr of the flake
  # there, through the link, or of its generated flake, after collecting
  # garbage.
  checkFlake = { attr, expected, subdir ? false, generated ? false }: ''
    link=$(readlink "$T"/x)
    ${if subdir then ''
      expect_eq subdirectory "$(basename "$link")" sub
      link=$(dirname "$link")
    '' else ""}
    expect_eq "store directory" "$(dirname "$link")" /nix/store
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
            inputs = optionalAttrs flags.inputs { dep.follows = "alt"; };
          };
        } // optionalAttrs flags.inputs alt;
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
        '' + optionalString flags.inputs ''
          # Inputs not drawn from sources aren't delivered, so this needs the
          # network and can't collect garbage before.
          expect_eq msg "$(nix_eval_online "$T"/.populate/flakes/x#msg)" top:alt,sub
        '';
      };
    };
  in
    matrix "file" {
      checksum = [ false true ];
      deleteExcluded = [ false true ];
      filters = [ false true ];
      inputs = [ false true ];
    } f
    ++ [
      # The deprecated exclude option, once, because it warns.
      (scenario (let
        args = f {
          checksum = false;
          deleteExcluded = true;
          exclude = true;
          filters = false;
          inputs = false;
        } null;
      in args // {
        name = "file-local-exclude";
        targetKind = "local";
        phases = [ (builtins.head args.phases) ];
      }))
    ];

  flake = matrix "flake" {
    kind = [ "git" "path" "subdir" "remote" ];
    fetchOnTarget = [ false true ];
    inputs = [ false true ];
  } (flags: ctx: let
    flake = {
      git = "/fixtures/top";
      path = "path:/fixtures/top";
      subdir = "git+file:/fixtures/mono?dir=sub";
      remote = "${url}/remote.tar.gz";
    }.${flags.kind};
    msg = {
      git = "top:${if flags.inputs then "alt" else "dep+inner"},sub";
      path = msg.git;
      remote = "remote:${if flags.inputs then "alt" else "dep+inner"}";
    };
  in
    # The flake in a subdirectory has no inputs to draw from sources.
    if flags.kind == "subdir" && flags.inputs then null else {
    isolate = true;
    phases = twice ({
      sources = {
        x.flake = {
          inherit flake;
          inherit (flags) fetchOnTarget;
          inputs = optionalAttrs flags.inputs { dep.follows = "alt"; };
        };
      } // optionalAttrs flags.inputs alt;
    } // (if copyingWithSudo flags ctx then {
      expect = "eval-error";
      control = withFetchOnTarget;
    } else {
      check = if flags.kind == "subdir" then checkFlake {
        attr = "who"; expected = "sub"; subdir = true;
      } else checkFlake {
        attr = "msg"; expected = msg.${flags.kind}; generated = flags.inputs;
      };
    }));
  });

  flake-input = concatMap
    (name: matrix "flake-input-${lib.replaceStrings ["/"] ["."] name}" ({
      fetchOnTarget = [ false true ];
    } // optionalAttrs (name == "dep") {
      inputs = [ false true ];
    }) (flags: ctx: let
      inputs = flags.inputs or false;
    in {
      isolate = true;
      phases = twice ({
        sources = {
          x.flake-input = {
            flake = "/fixtures/top";
            inherit name;
            inherit (flags) fetchOnTarget;
            inputs = optionalAttrs inputs { inner.follows = "alt"; };
          };
        } // optionalAttrs inputs alt;
      } // (if copyingWithSudo flags ctx then {
        expect = "eval-error";
        control = withFetchOnTarget;
      } else {
        check = {
          dep = checkFlake {
            attr = "greeting";
            expected = if inputs then "dep+alt" else "dep+inner";
            generated = inputs;
          };
          "dep/inner" = checkFlake { attr = "who"; expected = "inner"; };
          sub = checkFlake { attr = "who"; expected = "sub"; subdir = true; };
        }.${name};
      }));
    }))
    [ "dep" "dep/inner" "sub" ];

  git = matrix "git" {
    shallow = [ false true ];
    fetchAlways = [ false true ];
    cleanExclude = [ false true ];
    inputs = [ false true ];
  } (flags: _: let
    check = ''
      expect_eq HEAD "$(git -C "$T"/x rev-parse HEAD)" ${gitHead}
      expect_eq commits "$(git -C "$T"/x rev-list --count HEAD)" ${
        if flags.shallow then "1" else "2"
      }
      test -e "$T"/x/two || fail "two missing"
    '' + optionalString flags.inputs ''
      gc
      expect_eq msg "$(nix_eval "$T"/.populate/flakes/x#msg)" git:alt
    '';
    sources = {
      x.git = {
        url = gitUrl;
        ref = gitHead;
        inherit (flags) shallow fetchAlways;
        clean.exclude = optional flags.cleanExclude "keepme";
        inputs = optionalAttrs flags.inputs { dep.follows = "alt"; };
      };
    } // optionalAttrs flags.inputs alt;
  in {
    phases = [
      {
        inherit sources check;
        mutate = ''
          echo junk > "$T"/x/junk
          echo keepme > "$T"/x/keepme
        '';
      }
      {
        inherit sources;
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
    flake = [ false true ];
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
      ++ optionals flags.flake [ "--flake" "${build.path}/x" ]
      ++ optional (flags.etcFlake && !flags.flake) "--no-flake";
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
        sources.x =
          if flags.flake then {
            flake = {
              flake = "/fixtures/top";
              fetchOnTarget = ctx.targetKind == "sudo";
            };
          } else {
            file = "/fixtures/alt";
          };
        deploy = {
          flake = if flags.flake then "x" else null;
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
  in [
    # A generated flake draws an input from a source with a generated flake.
    (s "chain" {
      phases = twice {
        sources = alt // {
          a.flake = { flake = "/fixtures/top"; inherit fetchOnTarget; inputs.dep.follows = "b"; };
          b.flake-input = {
            flake = "/fixtures/top"; name = "dep"; inherit fetchOnTarget;
            inputs.inner.follows = "alt";
          };
        };
        check = ''
          gc
          expect_eq msg "$(nix_eval "$T"/.populate/flakes/a#msg)" top:dep+alt,sub
        '';
      };
    })
    # An input of an input drawn from a source gets overridden at that source.
    (s "nested" {
      phases = twice {
        sources = alt // {
          x.flake = {
            flake = "/fixtures/top"; inherit fetchOnTarget;
            inputs.dep = { follows = "b"; inputs.inner.follows = "alt"; };
          };
          b.flake-input = { flake = "/fixtures/top"; name = "dep"; inherit fetchOnTarget; };
        };
        check = ''
          gc
          expect_eq msg "$(nix_eval "$T"/.populate/flakes/x#msg)" top:dep+alt,sub
        '';
      };
    })
    # A generated flake gets removed once its source draws no inputs anymore.
    (s "removal" {
      phases = [
        {
          sources = alt // {
            x.flake = { flake = "/fixtures/top"; inherit fetchOnTarget; inputs.dep.follows = "alt"; };
          };
          check = ''
            test -e "$T"/.populate/flakes/x/flake.lock || fail "generated flake missing"
          '';
        }
        {
          sources = alt // {
            x.flake = { flake = "/fixtures/top"; inherit fetchOnTarget; };
          };
          check = ''
            test ! -e "$T"/.populate/flakes/x || fail "generated flake remains"
          '';
        }
      ];
    })
    # Roots follow the delivered input.
    (s "retarget" {
      phases = [
        {
          sources.x.flake-input = { flake = "/fixtures/top"; name = "dep"; inherit fetchOnTarget; };
          check = ''
            expect_eq roots "$(ls "$T"/.populate/flake-inputs/x | wc -l)" 1
          '';
        }
        {
          sources.x.flake-input = { flake = "/fixtures/top"; name = "sub"; inherit fetchOnTarget; };
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
        b.flake = { flake = "/fixtures/top"; inherit fetchOnTarget; };
        c.flake-input = { flake = "/fixtures/top"; name = "dep"; inherit fetchOnTarget; };
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
        sources.x.flake-input = { flake = "/fixtures/top"; name = "nope"; inherit fetchOnTarget; };
        expect.fail = "error: flake /fixtures/top has no input nope";
      }];
    })
    # An input locked to a path the target doesn't have.
    (s "gone" {
      phases = [{
        sources.x.flake = { flake = "/fixtures/usegone"; fetchOnTarget = true; };
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
  in [
    # The registry entry kropsremote, which fixtures.sh adds on the deploying
    # machine, points at ${url}/remote.tar.gz.  The deploying machine has no
    # global registry, which it couldn't download.
    (s "indirect" {
      phases = twice {
        sources.x.flake = { flake = "kropsremote"; inherit fetchOnTarget; };
        check = checkFlake { attr = "msg"; expected = "remote:dep+inner"; };
      };
    })
    (s "remote-subdir" {
      phases = twice {
        sources.x.flake = { flake = "${url}/mono.tar.gz?dir=sub"; inherit fetchOnTarget; };
        check = checkFlake { attr = "who"; expected = "sub"; subdir = true; };
      };
    })
    (s "subdir-inputs" {
      phases = twice {
        sources = alt // {
          x.flake = {
            flake = "git+file:/fixtures/monoin?dir=sub"; inherit fetchOnTarget;
            inputs.dep.follows = "alt";
          };
        };
        check = checkFlake { attr = "msg"; expected = "monoin:alt"; subdir = true; generated = true; };
      };
    })
    (s "dirty" {
      phases = twice {
        sources.x.flake = { flake = "/fixtures/dirty"; inherit fetchOnTarget; };
        check = checkFlake { attr = "msg"; expected = "dirty:dep+inner,sub"; } + ''
          test ! -e "$T"/x/untracked || fail "untracked file delivered"
        '';
      };
    })
    (s "unlocked" {
      phases = [{
        sources.x.flake = { flake = "/fixtures/unlocked"; inherit fetchOnTarget; };
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
        sources.x.flake-input = { flake = "/fixtures/top"; name = "dep/nope"; inherit fetchOnTarget; };
        expect.fail = "error: flake /fixtures/top has no input dep/nope";
      }];
    })
    (s "shared" {
      phases = twice {
        sources = {
          x.flake = { flake = "/fixtures/top"; inherit fetchOnTarget; };
          dep.flake-input = { flake = "/fixtures/top"; name = "dep"; inherit fetchOnTarget; };
          sub.flake-input = { flake = "/fixtures/top"; name = "sub"; fetchOnTarget = true; };
        };
        check = checkFlake { attr = "msg"; expected = "top:dep+inner,sub"; } + ''
          expect_eq dep "$(nix_eval "$T"/dep#greeting)" dep+inner
          expect_eq sub "$(nix_eval "$T"/sub#who)" sub
        '';
      };
    })
    (s "follows-empty" {
      phases = twice {
        sources.x.flake = { flake = "/fixtures/nofollow"; fetchOnTarget = true; };
        check = checkFlake { attr = "msg"; expected = "nofollow"; };
      };
    })
    (s "follows-cycle" {
      phases = twice {
        sources.x.flake = { flake = "/fixtures/cyc"; fetchOnTarget = true; };
        check = checkFlake { attr = "msg"; expected = "cyc:cyca,cycb"; };
      };
    })
    # Names resolve through the parent's lock file, so dep/inner is the
    # parent's inner, which dep's inner follows.
    (s "follows-name" {
      phases = twice {
        sources.x.flake-input = { flake = "/fixtures/follow"; name = "dep/inner"; inherit fetchOnTarget; };
        check = checkFlake { attr = "who"; expected = "inner2"; };
      };
    })
    # The delivered input comes with the inputs its own lock file pins, which
    # evaluating it needs, not with the parent's inner, which it follows there.
    (s "follows-closure" {
      phases = twice {
        sources.x.flake-input = { flake = "/fixtures/follow"; name = "dep"; inherit fetchOnTarget; };
        check = checkFlake { attr = "greeting"; expected = "dep+inner"; } + roots 1;
      };
    })
    (s "relative-input" {
      phases = twice {
        sources.x.flake = { flake = "/fixtures/rel"; fetchOnTarget = true; };
        check = checkFlake { attr = "msg"; expected = "rel:lib"; };
      };
    })
    (s "flake-to-file" {
      phases = [
        {
          sources.x.flake = { flake = "/fixtures/top"; inherit fetchOnTarget; };
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
          sources = alt // { x.flake = { flake = "/fixtures/top"; inherit fetchOnTarget; }; };
          check = checkFlake { attr = "msg"; expected = "top:dep+inner,sub"; } + ''
            test -e "$T"/alt/flake.nix || fail "alt changed"
          '';
        }
      ];
    })
  ] ++ lib.optional (targetKind == "local")
    # The target has the path the input is locked to.
    (s "uselocal" {
      phases = twice {
        sources.x.flake = { flake = "/fixtures/uselocal"; fetchOnTarget = true; };
        check = checkFlake { attr = "msg"; expected = "uselocal:alt"; };
      };
    })
  ) targetKinds;

}
