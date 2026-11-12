# Test scenarios for populate: every combination of each source type's
# options, deployed to the local machine, to a remote target as root, and to
# a remote target using sudo, plus scenarios for features spanning sources.
#
# A scenario prepares the target directory, then runs its phases.  Each phase
# runs populate, expecting it to succeed or to fail with a message, and checks
# the result on the target.  Phases expecting evaluation to fail get checked
# here and don't run.
{
  # nixpkgs' lib.
  lib,
  # krops' lib.
  krops,
  # Function from populate's arguments to the command running populate.
  populate,
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
    optional optionalAttrs optionalString;

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
  scenario = { name, targetKind, prepare ? "", phases }: let
    path = "/var/krops/${name}";
    target = targets.${targetKind} path;
    vars = "T=${path}\n";
    phase = { sources, prune ? false, expect ? "success", check ? "", mutate ? null }: let
      command = populate {
        source = krops.evalSource [ sources ];
        inherit prune target;
        force = true;
      };
      evaluated = builtins.tryEval (builtins.seq (toString command) true);
    in
      if expect == "eval-error" then
        if evaluated.success then
          throw "scenario ${name}: populate evaluates, but is expected to fail"
        else
          null
      else {
        populate = toString command;
        expect = if expect == "success" then null else expect.fail;
        check = prelude + vars + check;
        mutate = if mutate == null then null else prelude + vars + mutate;
      };
  in {
    inherit name;
    node = if targetKind == "local" then "deployer" else "target";
    prepare = prelude + vars + ''
      rm -fR "$T"
    '' + prepare;
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

in {

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

  # Features spanning several sources.
  features = concatMap (targetKind: let
    s = name: args: scenario ({ name = "${name}-${targetKind}"; inherit targetKind; } // args);
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
      }];
    })
    (s "self" {
      phases = [{
        sources.a.file = { path = "/fixtures/alt"; inputs.foo.follows = "a"; };
        expect = "eval-error";
      }];
    })
    (s "missing" {
      phases = [{
        sources.a.file = { path = "/fixtures/alt"; inputs.foo.follows = "nope"; };
        expect = "eval-error";
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

}
