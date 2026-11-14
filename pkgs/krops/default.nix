{ expect, lib, nix, openssh, populate, populate-unwrapped, writers }:

let
  klib = import ../../lib/with.nix { inherit lib; };
  targets = import ./target.nix { inherit lib; };

  # What populate and populate shell get for target: a string as it is, so
  # populate fills in what it leaves out when it runs, and an attribute set
  # with mkTarget's defaults.
  given = target:
    if builtins.isString target then target else klib.mkTarget target;

  # Shell code running populate shell with options, for running the shell
  # code command on target.
  populateShell = options: target: command: /* sh */ ''
    PATH=${lib.makeBinPath [ openssh ]}''${PATH:+:$PATH} \
    ${populate-unwrapped}/bin/populate shell ${lib.escapeShellArgs (
      options ++ targets.shellArgs (given target) command
    )}
  '';
in

rec {

  rebuild = {
    allocateTTY ? false,
    flake ? null,
    useNixOutputMonitor
  }:
  args: target: let
    inherit (klib.mkTarget target) path;
    # The flake's directory in the target directory, and the name of the
    # NixOS configuration with its #, if any.
    flakeDir = lib.head (lib.splitString "#" flake);
    flakeAttr = lib.removePrefix flakeDir flake;
  in
    runShell target { inherit allocateTTY; } (
      # Without ssh, which allocates the terminal on remote targets, unbuffer
      # gives nixos-rebuild one.  populate shell tells whether the target is
      # local as $1, which nix-shell doesn't pass on, so it goes into the
      # environment.
      lib.optionalString allocateTTY /* sh */ ''
        if test "$1" = local; then
          krops_unbuffer=${expect}/bin/unbuffer
        else
          krops_unbuffer=
        fi
        export krops_unbuffer
      '' +
      withNixOutputMonitor target useNixOutputMonitor /* sh */ ''
        ${lib.optionalString (flake != null) /* sh */ ''
          ${klib.shell.requireFlakes "deploying a flake"}
          ${klib.shell.urlPath}
          # A Git work tree gets deployed as such.  Anything else gets
          # deployed as path:, not just by its path, which Nix takes for the
          # enclosing Git work tree, if any.  Nix refuses URLs with symlinks
          # on the way, which the target directory may be, or the source.
          flake=$(readlink -f ${lib.escapeShellArg "${path}/${flakeDir}"})
          if test -e "$flake"/.git; then
            if test -e "$flake"/.gitmodules; then
              flake=git+file:$(url_path "$flake")?submodules=1
            else
              flake=git+file:$(url_path "$flake")
            fi
          else
            flake=path:$(url_path "$flake")
          fi
        ''}
        NIX_PATH=${lib.escapeShellArg path} \
        ${lib.optionalString allocateTTY "$krops_unbuffer"} \
        nixos-rebuild ${lib.escapeShellArgs args} ${
          if flake != null then
            ''--flake "$flake"${lib.escapeShellArg flakeAttr}''
          else
            # nixos-rebuild deploys /etc/nixos/flake.nix if it exists.  Any
            # nixos-rebuild doing so supports --no-flake.
            "$(test -e /etc/nixos/flake.nix && echo --no-flake)"
        }
      '');

  # Shell code running the shell code command on target, reached like
  # populate reaches it, with local or remote as $1, telling whether the
  # target is local.
  runShell = target: {
    allocateTTY ? false
  }: populateShell (lib.optional allocateTTY "--tty") target;

  withNixOutputMonitor = target: mode_: command: let
    mode =
      lib.getAttr (lib.typeOf mode_)  {
        bool = lib.toJSON mode_;
        string = mode_;
      };
  in /* sh */ ''
    printf '# use nix-output-monitor: %s\n' ${lib.escapeShellArg mode} >&2
    ${lib.getAttr mode rec {
      opportunistic = /* sh */ ''
        if command -v nom >/dev/null; then
          ${optimistic}
        else
          ${false}
        fi
      '';
      optimistic = /* sh */ ''
        (${command}) 2>&1 | nom
      '';
      pessimistic = /* sh */ ''
        NIX_PATH=${lib.escapeShellArg (klib.mkTarget target).path} \
        nix-shell -p nix-output-monitor --run ${lib.escapeShellArg optimistic}
      '';
      true = /* sh */ ''
        if command -v nom >/dev/null; then
          ${optimistic}
        else
          ${pessimistic}
        fi
      '';
      false = command;
    }}
  '';

  writeCommand = name: {
    command ? (targetPath: "echo ${targetPath}"),
    backup ? false,
    force ? false,
    allocateTTY ? false,
    prune ? false,
    source,
    target
  }: let
    target' = klib.mkTarget target;
  in
    writers.writeDash name ''
      set -efu
      ${populate { inherit backup force prune source; target = given target; }}
      ${runShell target { inherit allocateTTY; } (command target'.path)}
    '';

  writeDeploy = name: {
    allocateTTY ? false,
    backup ? false,
    buildTarget ? null,
    crossDeploy ? false,
    fast ? null,
    flake ? null,
    force ? false,
    operation ? "switch",
    prune ? false,
    source,
    target,
    useNixOutputMonitor ? "opportunistic"
  }: let
    buildTarget' =
      if buildTarget == null
        then target'
        else klib.mkTarget buildTarget;
    target' = klib.mkTarget target;
    # A host as nixos-rebuild takes it.  Without a user, ssh decides.  Pure
    # evaluation can't tell the machine's name, which mkTarget defaults the
    # host to.
    userHost = target:
      lib.optionalString (target.user != null && target.user != "")
        "${target.user}@" +
      (if target.host != null then target.host
       else throw "krops: writeDeploy: a target with a separate buildTarget needs a host in pure evaluation");
    separateBuild = buildTarget' != target';
    # The source's generated flake, if it draws inputs from other sources.
    flake' = let
      name = lib.head (lib.splitString "#" flake);
    in
      if flake == null then null
      else if !(source ? ${name}) then
        throw "krops: flake ${name} is not a source"
      else if klib.hasGeneratedFlake source.${name} then
        ".populate/flakes/${flake}"
      else
        flake;
  in
    lib.traceIf (fast != null) "writeDeploy: it's now always fast, setting the `fast` attribute is deprecated and will be removed in future" (
      writers.writeDash name ''
        set -efu
        ${lib.optionalString separateBuild
          (populate { inherit backup force prune source; target = given buildTarget; })}
        ${populate { inherit backup force prune source; target = given target; }}
        ${rebuild { flake = flake'; inherit allocateTTY useNixOutputMonitor; } ([
          operation
        ] ++ lib.optionals crossDeploy [
          "--no-build-nix"
        ] ++ lib.optionals separateBuild [
          "--build-host" (userHost buildTarget')
          "--target-host" (userHost target')
        ] ++ lib.optionals (separateBuild && target'.sudo) [
          # nixos-rebuild runs on the target itself via sudo otherwise.
          "--use-remote-sudo"
        ]) (if separateBuild then buildTarget else target)}
      ''
    );

  writeTest = name: {
    backup ? false,
    force ? false,
    prune ? false,
    source,
    target,
    trace ? false
  }: let
    target' = klib.mkTarget target;
  in
    # Pure evaluation can't tell, so populate shell tells when it runs.
    assert targets.pure || klib.isLocalTarget target';
    writers.writeDash name ''
      set -efu
      ${populateShell [ "--local-only" ] target "true"}
      ${populate { inherit backup force prune source; target = given target; }} >&2
      NIX_PATH=${lib.escapeShellArg target'.path} \
      ${nix}/bin/nix-build \
          -A system \
          --keep-going \
          --no-out-link \
          ${lib.optionalString trace "--show-trace"} \
          '<nixpkgs/nixos>'
    '';
}
