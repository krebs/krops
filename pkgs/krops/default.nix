let
  lib = import ../../lib;
in

{ nix, openssh, populate, writers }: rec {

  rebuild = args: target:
    runShell target {} "nixos-rebuild -I ${lib.escapeShellArg target.path} ${
      lib.concatMapStringsSep " " lib.escapeShellArg args
    }";

  runShell = target: {
    allocateTTY ? false
  }: command:
    let
      command' = if target.sudo then "sudo ${command}" else command;
    in
      if lib.isLocalTarget target
      then command'
      else
        writers.writeDash "krops.${target.host}.${lib.firstWord command}" ''
          exec ${openssh}/bin/ssh ${lib.escapeShellArgs (lib.flatten [
            (lib.mkUserPortSSHOpts target)
            (if allocateTTY then "-t" else "-T")
            target.extraOptions
            target.host
            command'])}
        '';

  writeCommand = name: {
    command ? (targetPath: "echo ${targetPath}"),
    backup ? false,
    force ? false,
    allocateTTY ? false,
    source,
    target
  }: let
    target' = lib.mkTarget target;
  in
    writers.writeDash name ''
      set -efu
      ${populate { inherit backup force source; target = target'; }}
      ${runShell target' { inherit allocateTTY; } (command target'.path)}
    '';

  writeDeploy = name: {
    backup ? false,
    buildTarget ? null,
    crossDeploy ? false,
    fast ? null,
    force ? false,
    source,
    target
  }: let
    buildTarget' =
      if buildTarget == null
        then target'
        else lib.mkTarget buildTarget;
    target' = lib.mkTarget target;
  in
    lib.traceIf (fast != null) "writeDeploy: it's now always fast, setting the `fast` attribute is deprecated and will be removed in future" (
      writers.writeDash name ''
        set -efu
        ${lib.optionalString (buildTarget' != target')
          (populate { inherit backup force source; target = buildTarget'; })}
        ${populate { inherit backup force source; target = target'; }}
        ${rebuild ([
          "switch"
        ] ++ lib.optionals crossDeploy [
          "--no-build-nix"
        ] ++ lib.optionals (buildTarget' != target') [
          "--build-host" "${buildTarget'.user}@${buildTarget'.host}"
          "--target-host" "${target'.user}@${target'.host}"
        ] ++ lib.optionals target'.sudo [
          "--use-remote-sudo"
        ]) buildTarget'}
      ''
    );

  writeTest = name: {
    backup ? false,
    force ? false,
    source,
    target
  }: let
    target' = lib.mkTarget target;
  in
    assert lib.isLocalTarget target';
    writers.writeDash name ''
      set -efu
      ${populate { inherit backup force source; target = target'; }} >&2
      NIX_PATH=${lib.escapeShellArg target'.path} \
      ${nix}/bin/nix-build \
          -A system \
          --keep-going \
          --no-out-link \
          --show-trace \
          '<nixpkgs/nixos>'
    '';
}
