# Test scenarios for krops, besides populate's, which run through
# pkgs.populate here: writeDeploy's arguments to nixos-rebuild, which a
# stand-in records.  The arguments are those of populate's builder.nix,
# and targets, which give the target of each kind for a path.
{ targets, ... }@args:

let
  inherit (args) lib gitHead gitUrl remoteHost;
  inherit (lib) concatMap concatStringsSep optional optionalAttrs optionals optionalString;
  inherit (import ../pkgs/populate/tests/builder.nix (removeAttrs args [ "targets" ]))
    alt drawInputs matrix scenario targetKinds twice;

  # The target of a kind for a path, as a string, which can't say to use
  # sudo.
  targetString = targetKind: path: {
    local = path;
    remote = "root@${remoteHost}${path}";
  }.${targetKind};
in

{

  # writeDeploy's arguments to nixos-rebuild, which a stand-in records.
  # flake is what gets deployed: nothing, or a flake from a file, git, or
  # flake source, or one whose inputs get drawn from a source, by rewriting
  # its lock file or through a generated flake.  targetString gives the
  # target as a string, which populate and populate shell get as it is.
  deploy = matrix "deploy" {
    flake = [ "none" "file" "git" "source" "rewrite" "generated" ];
    etcFlake = [ false true ];
    buildTarget = [ false true ];
    targetString = [ false true ];
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
    # The local target can't have another build target, and a string can't
    # say to use sudo.
    if flags.buildTarget && ctx.targetKind == "local" ||
        flags.targetString && ctx.targetKind == "sudo" then null else {
      node = if flags.buildTarget then "deployer" else null;
      # /etc/nixos/flake.nix only matters if no flake gets deployed, and
      # how the target is given not for what gets deployed.
      exhaustive = flags.etcFlake && flags.flake != "none" ||
        flags.targetString && flags.flake != "none";
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
        } // optionalAttrs flags.targetString {
          target = targetString ctx.targetKind ctx.path;
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
    })

  # writeDeploy with allocateTTY: nixos-rebuild's output is a terminal on
  # the local target.  ssh allocates one on remote targets only if its own
  # input is a terminal, which the tests' isn't.  Whether the target is
  # local, populate shell decides, also for a target string.
  ++ concatMap (targetKind: map (string: scenario (rec {
    name = "deploy-${targetKind}${optionalString string "-string"}-allocateTTY";
    inherit targetKind;
    prepare = ''
      rm -f /tmp/nixos-rebuild.log /etc/nixos/flake.nix
    '';
    phases = [{
      sources.x.file = "/fixtures/alt";
      deploy = {
        allocateTTY = true;
      } // optionalAttrs string {
        target = targetString targetKind "/var/krops/${name}";
      };
      check = ''
        expect_eq arguments "$(sed -n 3p /tmp/nixos-rebuild.log)" switch
        expect_eq terminal "$(sed -n 4p /tmp/nixos-rebuild.log)" ${
          if targetKind == "local" then "terminal" else "'no terminal'"
        }
      '';
    }];
  })) (if targetKind == "sudo" then [ false ] else [ false true ])) targetKinds;

}
