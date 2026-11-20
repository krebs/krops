# Test scenarios for populate: every combination of each source type's
# options, delivered to the local machine, to a remote target as root, and
# to a remote target using sudo, plus scenarios for features spanning
# sources.  The arguments are those of builder.nix, which builds them.
args:

let
  inherit (args) lib agePath gitFirst gitHead gitUrl rsyncVersion url;
  inherit (lib) concatMap optional optionalAttrs optionalString;
  inherit (import ./builder.nix args)
    alt checkFlake copyingWithSudo drawInputs flakeOf inputModes matrix
    refuseCopyingWithSudo scenario targetKinds targetName twice;
in

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
    } // (if copyingWithSudo flags ctx then refuseCopyingWithSudo else {
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
      } // (if copyingWithSudo flags ctx then refuseCopyingWithSudo else {
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
          echo changed > "$T"/x/two
        '';
      }
      {
        sources = sources gitHead;
        check = check + ''
          expect_eq two "$(cat "$T"/x/two)" two
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
  # Branches and tags follow the server: a branch that moves between two
  # deploys, and a tag, with full and shallow clones.
  ++ concatMap (targetKind: map (shallow: scenario {
    name = "git-${targetKind}-shallow${if shallow then "1" else "0"}-refs";
    inherit targetKind;
    prepareDeployer = ''
      git -C /fixtures/git/gitsrc.git update-ref refs/heads/moving ${gitFirst}
      git -C /fixtures/git/gitsrc.git update-ref refs/tags/first ${gitFirst}
    '';
    phases = [
      {
        sources.x.git = { url = gitUrl; ref = "moving"; inherit shallow; };
        check = ''
          expect_eq HEAD "$(git -C "$T"/x rev-parse HEAD)" ${gitFirst}
        '';
        mutateDeployer = ''
          git -C /fixtures/git/gitsrc.git update-ref refs/heads/moving ${gitHead}
        '';
      }
      {
        sources.x.git = { url = gitUrl; ref = "moving"; inherit shallow; };
        check = ''
          expect_eq HEAD "$(git -C "$T"/x rev-parse HEAD)" ${gitHead}
        '';
      }
      {
        sources.x.git = { url = gitUrl; ref = "first"; inherit shallow; };
        check = ''
          expect_eq HEAD "$(git -C "$T"/x rev-parse HEAD)" ${gitFirst}
        '';
      }
    ];
  }) [ false true ]) targetKinds

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

  # identities_file defaults to the identities in the home directory.
  passage = matrix "passage" {
    age = [ "default" "path" ];
    dir = [ "store" "subdir" ];
    identities = [ "file" "home" ];
  } (flags: _: {
    exhaustive = flags.identities == "home" &&
      (flags.age != "default" || flags.dir != "store");
    phases = twice {
      sources.x.passage = {
        dir = "/fixtures/passage/store" + optionalString (flags.dir == "subdir") "/x";
      } // optionalAttrs (flags.identities == "file") {
        identities_file = "/fixtures/passage/identities";
      } // optionalAttrs (flags.age == "path") {
        age = agePath;
      };
      env = optionalString (flags.identities == "home") "HOME=/fixtures/passage-home";
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
    # get drawn from changes.  What Nix prints about a generated flake's lock
    # file only gets printed then.
    (modes "relock" ({ draw, flake, mode, ... }: let
      x.file = { path = "/fixtures/filesrc"; } // draw { dep.follows = "a"; };
      generated = optional (mode == "generated");
    in {
      phases = [
        {
          sources = { inherit x; a.file = "/fixtures/alt"; };
          check = ''
            expect_eq msg "$(nix_eval_online ${flake "x"}#msg)" top:alt,sub
          '';
          output = generated "creating lock file";
        }
        {
          sources = { inherit x; a.file = "/fixtures/alt"; };
          check = ''
            expect_eq msg "$(nix_eval_online ${flake "x"}#msg)" top:alt,sub
          '';
          unexpected = generated "lock file";
        }
        {
          output = generated "creating lock file";
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
    # A copy with a rewritten lock file that draws an input from a Git work
    # tree, which Nix gets as git+file:, gets made again only when the
    # commit or the tracked files change, not for an untracked file, which
    # Nix doesn't see.  The source is a file source keeping its .git.
    (s "rewrite-cache-git" (let
      sources = {
        x.flake-input = {
          url = "/fixtures/top"; name = "dep"; inherit fetchOnTarget;
          inputs.inner.follows = "a";
        };
        a.file = "/tmp/rewrite-cache-git";
      };
      copyKept = ''
        expect_eq "store path" "$(readlink "$T"/x)" "$(cat "$T".first)"
        expect_eq "copy made at" "$(stat -c %y "$T"/.populate/derived/x/key)" "$(cat "$T".key)"
      '';
    in {
      prepareDeployer = ''
        rm -fR /tmp/rewrite-cache-git
        mkdir /tmp/rewrite-cache-git
        cd /tmp/rewrite-cache-git
        echo '{ outputs = _: { who = "altgit"; }; }' > flake.nix
        git init -q
        git add flake.nix
        git -c user.name=krops -c user.email=spam@krebsco.de commit -q -m altgit
      '';
      phases = [
        {
          inherit sources;
          check = checkFlake { attr = "greeting"; expected = "dep+altgit"; };
          mutate = ''
            readlink "$T"/x > "$T".first
            stat -c %y "$T"/.populate/derived/x/key > "$T".key
          '';
        }
        {
          inherit sources;
          check = copyKept;
          mutateDeployer = ''
            echo untracked > /tmp/rewrite-cache-git/untracked
          '';
        }
        {
          inherit sources;
          check = copyKept + ''
            test -e "$T"/a/untracked || fail "a/untracked missing"
          '';
          mutateDeployer = ''
            cd /tmp/rewrite-cache-git
            echo '{ outputs = _: { who = "altgit2"; }; }' > flake.nix
            git -c user.name=krops -c user.email=spam@krebsco.de commit -q -a -m altgit2
          '';
        }
        {
          inherit sources;
          check = checkFlake { attr = "greeting"; expected = "dep+altgit2"; } + ''
            test "$(readlink "$T"/x)" != "$(cat "$T".first)" || fail "store path unchanged"
          '';
        }
      ];
    }))
    # Like rewrite-cache-git, with a git source, which populate checks
    # once per run, when delivering it, and the flakes step doesn't check
    # again.
    (s "rewrite-cache-gitsource" (let
      sources = {
        x.flake-input = {
          url = "/fixtures/top"; name = "dep"; inherit fetchOnTarget;
          inputs.inner.follows = "g";
        };
        g.git = { url = "git://deployer/rewrite-cache-gitsource.git"; ref = "master"; };
      };
      commit = who: ''
        cd /tmp/rewrite-cache-gitsource
        echo '{ outputs = _: { who = "${who}"; }; }' > flake.nix
        git add flake.nix
        git -c user.name=krops -c user.email=spam@krebsco.de commit -q -m ${who}
        git push -q -f /fixtures/git/rewrite-cache-gitsource.git master
      '';
    in {
      prepareDeployer = ''
        rm -fR /tmp/rewrite-cache-gitsource /fixtures/git/rewrite-cache-gitsource.git
        git init -q --bare /fixtures/git/rewrite-cache-gitsource.git
        git init -q -b master /tmp/rewrite-cache-gitsource
      '' + commit "gitsource";
      phases = [
        {
          inherit sources;
          check = checkFlake { attr = "greeting"; expected = "dep+gitsource"; } + ''
            grep -q '"type": "git"' "$T"/x/flake.lock ||
              fail "g isn't referred to as git+file:"
          '';
          mutate = ''
            readlink "$T"/x > "$T".first
            stat -c %y "$T"/.populate/derived/x/key > "$T".key
          '';
        }
        {
          inherit sources;
          check = ''
            expect_eq "store path" "$(readlink "$T"/x)" "$(cat "$T".first)"
            expect_eq "copy made at" "$(stat -c %y "$T"/.populate/derived/x/key)" "$(cat "$T".key)"
          '';
          mutateDeployer = commit "gitsource2";
        }
        {
          inherit sources;
          check = checkFlake { attr = "greeting"; expected = "dep+gitsource2"; } + ''
            test "$(readlink "$T"/x)" != "$(cat "$T".first)" || fail "store path unchanged"
          '';
        }
      ];
    }))
    # The record of a run: what got delivered, and whether anything changed
    # since the last record, also in runs that failed, which leave the
    # record as it was.
    (s "record" (let
      sources = {
        g.git = { url = gitUrl; ref = gitHead; };
        l.symlink = "x";
        x.file = "/fixtures/alt";
      };
      # Whether x, and g and l, changed.
      changed = x: others: ''
        expect_eq changed "$(record changed)" ${if x || others then "true" else "false"}
        expect_eq "x changed" "$(record sources.x.changed)" ${lib.boolToString x}
        expect_eq "g changed" "$(record sources.g.changed)" ${lib.boolToString others}
        expect_eq "l changed" "$(record sources.l.changed)" ${lib.boolToString others}
      '';
    in {
      phases = [
        {
          inherit sources;
          check = changed true true + ''
            expect_eq version "$(record version)" 0
            expect_eq "x type" "$(record sources.x.type)" '"file"'
            expect_eq "g commit" "$(record sources.g.commit)" '"${gitHead}"'
            expect_eq "l target" "$(record sources.l.target)" '"x"'
            test ! -e "$T"/.populate/journal || fail "journal remains"
          '';
        }
        {
          inherit sources;
          check = changed false false + ''
            cp "$T"/.populate/run.json "$T".record
          '';
          mutate = ''
            echo changed > "$T"/x/flake.nix
          '';
        }
        {
          # x, which comes before y, gets delivered again.
          sources = sources // { y.pipe = "/run/current-system/sw/bin/false"; };
          expect = { fail = ""; status = 1; };
          check = ''
            cmp "$T"/.populate/run.json "$T".record || fail "record changed"
            test -e "$T"/.populate/journal || fail "journal missing"
          '';
        }
        {
          # What the failed run changed.
          inherit sources;
          check = changed true false;
        }
      ];
    }))
    # A consumer of the target directory holding a shared lock delays the
    # next run.
    (s "lock" {
      phases = [
        {
          sources.x.file = "/fixtures/alt";
          mutate = ''
            setsid flock --shared "$T"/.populate/lock sleep 5 \
                </dev/null >/dev/null 2>&1 &
            sleep 1
          '';
        }
        {
          sources.x.file = "/fixtures/alt";
          output = [ "waiting for the lock on" ];
        }
      ];
    })
    # The command holding the lock ending, here when a pipe source kills
    # it, or what runs it on the deploying machine, fails the run before the
    # next command on the target, without a record.  On a remote target,
    # that's the ssh client running it, and on the local one the command
    # itself, cat by then, holding the lock file open.
    (s "lock-lost" {
      prepareDeployer = ''
        cat > /tmp/lose-lock <<'EOF'
        #!/bin/sh
        pkill -f 'exec cat >/dev/null' || :
        for fd in /proc/[0-9]*/fd/*; do
          case $(readlink "$fd" 2>/dev/null) in
            */.populate/lock)
              pid=''${fd#/proc/}
              kill "''${pid%%/*}" || :
              ;;
          esac
        done
        sleep 1
        echo x
        EOF
        chmod +x /tmp/lose-lock
      '';
      phases = [{
        sources = {
          a.pipe = "/tmp/lose-lock";
          b.symlink = "a";
        };
        expect.fail = "error: populate lost the lock on";
        check = ''
          test ! -e "$T"/.populate/run.json || fail "record written"
          test -e "$T"/.populate/journal || fail "journal missing"
        '';
      }];
    })
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
            (name: "pruning '${targetName targetKind "/var/krops/prune-${targetKind}/${name}"}'...")
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
        refused = "krops: sources draw inputs from each other: a b";
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
        refused = "krops: source a draws inputs from itself";
        control = alt // {
          a.file = { path = "/fixtures/alt"; inputs.foo.follows = "alt"; };
        };
      }];
    })
    (s "missing" {
      phases = [{
        sources.a.file = { path = "/fixtures/alt"; inputs.foo.follows = "nope"; };
        expect = "eval-error";
        refused = "krops: source a draws inputs from missing source nope";
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
    # rsync's log gives sizes in units of 1024, as %'''l asks for.
    (s "rsync-units" {
      prepareDeployer = ''
        rm -fR /tmp/rsync-units
        mkdir /tmp/rsync-units
        head -c 2048 /dev/zero > /tmp/rsync-units/f
      '';
      phases = [{
        sources.x.file = "/tmp/rsync-units";
        output = [ "/2.00K" ];
      }];
    })
    # A pipe command without #!, which a shell runs as a script.
    (s "pipe-script" {
      prepareDeployer = ''
        printf 'echo piped\n' > /tmp/pipe-script
        chmod +x /tmp/pipe-script
      '';
      phases = [{
        sources.x.pipe = "/tmp/pipe-script";
        check = ''
          expect_eq x "$(cat "$T"/x)" piped
        '';
      }];
    })
    # A pass source gets decrypted again only when the last commit of its
    # passwords changes, which .pass_info records.
    (s "pass-changes" (let
      sources.x.pass = { dir = "/tmp/pass-changes"; name = "x"; };
    in {
      prepareDeployer = ''
        rm -fR /tmp/pass-changes
        cp -R /fixtures/pass-git /tmp/pass-changes
      '';
      phases = [
        {
          inherit sources;
          check = ''
            expect_eq a "$(cat "$T"/x/a)" secret-a
          '';
          mutate = ''
            echo local-change > "$T"/x/a
          '';
        }
        {
          inherit sources;
          check = ''
            expect_eq a "$(cat "$T"/x/a)" local-change
          '';
          mutateDeployer = ''
            export GIT_AUTHOR_NAME=krops GIT_AUTHOR_EMAIL=spam@krebsco.de
            export GIT_COMMITTER_NAME=krops GIT_COMMITTER_EMAIL=spam@krebsco.de
            printf 'secret-b\n' |
              PASSWORD_STORE_DIR=/tmp/pass-changes pass insert -m -f x/a >/dev/null
          '';
        }
        {
          inherit sources;
          check = ''
            expect_eq a "$(cat "$T"/x/a)" secret-b
          '';
        }
      ];
    }))
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
        # Locking the flake with an empty URL would lock the current
        # directory, the login directory on a remote target.
        unexpected = [ "while fetching the input" ];
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
            "replacing symlink '${targetName targetKind "/var/krops/link-${type}-${targetKind}/x"}', which points to '${outside}/${to}'...";
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
        output = [
          "f+++++++++ flake.nix " "/53"
          # Named like pruning names it.
          "populating '${targetName targetKind "/var/krops/rsync-log-${targetKind}/x"}'..."
        ];
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
      (file: state file {
        entry = ".populate/${file}";
        message = "/.populate/${file} is a symlink, but populate needs a file of its own there";
      })
      [ "lock" "journal" ])
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
        expect.fail = "error: populate doesn't use the Git work tree ${targetName targetKind "/var/krops/git-foreign-${targetKind}/${name}"}, because ${message}.  Fix that, remove the work tree, or set the source's reclone to true to replace it by a fresh clone.";
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
            (name: "replacing the Git work tree '${targetName targetKind "/var/krops/git-foreign-${targetKind}/${name}"}', because")
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
    # A Git work tree whose submodule's .git, which Git uses as it finds it,
    # isn't the gitfile git clone made, naming the repository in
    # .git/modules: a repository of its own, whose configuration names a
    # command, and a gitfile naming a repository elsewhere.
    (s "git-submodule" (let
      elsewhere = "/var/krops-elsewhere";
      url = dirOf gitUrl + "/withsub.git";
      git = reclone: { x.git = { inherit url reclone; ref = "master"; }; };
      untouched = ''
        test ! -e ${elsewhere}/ran || fail "a command in a .git directory ran"
        expect_eq "HEAD elsewhere" "$(git -C ${elsewhere}/repo rev-parse HEAD)" ${gitFirst}
      '';
    in {
      isolate = true;
      prepare = ''
        rm -fR ${elsewhere}
        git clone -q ${gitUrl} ${elsewhere}/repo
        git -C ${elsewhere}/repo checkout -q ${gitFirst}
      '';
      phases = [
        {
          sources = git false;
          check = untouched + ''
            expect_eq "sub HEAD" "$(git -C "$T"/x/sub rev-parse HEAD)" ${gitHead}
          '';
          mutate = ''
            rm "$T"/x/sub/.git
            cp -R "$T"/x/.git/modules/sub "$T"/x/sub/.git
            git config --file "$T"/x/sub/.git/config --unset core.worktree
            git config --file "$T"/x/sub/.git/config \
                filter.x.smudge "touch ${elsewhere}/ran; cat"
            echo '* filter=x' > "$T"/x/sub/.git/info/attributes
            git -C "$T"/x/sub update-ref --no-deref HEAD ${gitFirst}
            git -C "$T"/x/sub read-tree ${gitFirst}
            rm "$T"/x/sub/two
          '';
        }
        {
          sources = git false;
          expect.fail = "error: populate doesn't use the Git work tree";
          check = untouched;
          mutate = ''
            rm -fR "$T"/x/sub
            mkdir "$T"/x/sub
            echo gitdir: ${elsewhere}/repo/.git > "$T"/x/sub/.git
          '';
        }
        {
          sources = git false;
          expect.fail = "error: populate doesn't use the Git work tree";
          check = untouched;
        }
        {
          sources = git true;
          check = untouched + ''
            expect_eq "sub HEAD" "$(git -C "$T"/x/sub rev-parse HEAD)" ${gitHead}
          '';
        }
      ];
    }))
    # A ref that git fetch would take for an option: --upload-pack runs a
    # command where the repository is local.
    (s "git-ref-option" (let
      elsewhere = "/var/krops-elsewhere";
    in {
      isolate = true;
      prepare = ''
        rm -fR ${elsewhere}
        git clone -q --bare ${gitUrl} ${elsewhere}/repo.git
      '';
      phases = [
        {
          sources.x.git = {
            url = "${elsewhere}/repo.git";
            ref = "--upload-pack=touch ${elsewhere}/ran; git-upload-pack";
          };
          expect.fail = "invalid refspec";
          check = ''
            test ! -e ${elsewhere}/ran || fail "the ref ran a command"
          '';
        }
      ];
    }))
    # populate exits with the status of the command that failed, here git
    # fetch's.
    (s "git-status" {
      phases = [{
        sources.x.git = { url = gitUrl; ref = "nonexistent"; };
        expect = { fail = "couldn't find remote ref"; status = 128; };
      }];
    })
    # A .git that a materialized flake got, and one that a file source
    # keeps, which Nix uses for the git+file: URL of the flake there: writing
    # its lock file, Nix runs Git, with that repository's configuration.
    (s "lock-foreign-git" (let
      elsewhere = "/var/krops-elsewhere";
      sources = alt // {
        x.flake-input = {
          url = "/fixtures/top"; name = "dep"; inherit fetchOnTarget;
          materialize = true;
          inputs.inner.follows = "alt";
        };
        y.file = {
          path = "/fixtures/filesrc";
          deleteExcluded = false;
          filters = [ { type = "exclude"; pattern = "/.git"; } ];
          inputs.dep.follows = "alt";
        };
      };
    in {
      isolate = true;
      prepare = ''
        rm -fR ${elsewhere}
        mkdir -p ${elsewhere}
      '';
      phases = [
        {
          inherit sources;
          # Repositories tracking only flake.nix, so the lock file changes.
          mutate = ''
            for name in x y; do
              git -C "$T"/$name init -q
              git -C "$T"/$name add flake.nix
              git -C "$T"/$name -c user.name=x -c user.email=x@x commit -q -m x
              git -C "$T"/$name config core.fsmonitor "touch ${elsewhere}/ran; false"
            done
          '';
        }
        {
          inherit sources;
          check = ''
            test ! -e ${elsewhere}/ran || fail "a command in a .git directory ran"
          '';
        }
      ];
    }))
    # A .git that a file source keeps, with configuration a git source would
    # use, but a hook, which Nix's Git runs when it adds the lock file it
    # writes: populate's Git runs none, so git sources keep hooks, but
    # drawing inputs refers to the flake as path:.
    (s "lock-hooks" (let
      elsewhere = "/var/krops-elsewhere";
      sources = alt // {
        y.file = {
          path = "/fixtures/filesrc";
          deleteExcluded = false;
          filters = [ { type = "exclude"; pattern = "/.git"; } ];
          inputs.dep.follows = "alt";
        };
      };
    in {
      isolate = true;
      prepare = ''
        rm -fR ${elsewhere}
        mkdir -p ${elsewhere}
      '';
      phases = [
        {
          inherit sources;
          # A repository tracking only flake.nix, so Nix adds the lock file,
          # which runs post-index-change.
          mutate = ''
            git -C "$T"/y init -q
            git -C "$T"/y add flake.nix
            git -C "$T"/y -c user.name=x -c user.email=x@x commit -q -m x
            printf '#! /bin/sh\ntouch ${elsewhere}/ran\n' > "$T"/y/.git/hooks/post-index-change
            chmod +x "$T"/y/.git/hooks/post-index-change
          '';
        }
        {
          inherit sources;
          check = ''
            test ! -e ${elsewhere}/ran || fail "a hook in a .git directory ran"
            test -e "$T"/y/flake.lock || fail "y/flake.lock missing"
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
            refused = "krops: source name";
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
            refused =
              if targetPath == "" then "the target's path is empty"
              else "krops: target path";
            controlTargetPath = "/var/krops/paths-local";
          })
          [ "" "/" "//" "/." "relative" "/var/krops/.." "/var/krops/../.." "/var/krops/a\nb" ];
      })
    ])
  ]) targetKinds;

}
