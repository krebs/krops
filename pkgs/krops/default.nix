let
  lib = import ../../lib;
in

{ nix, openssh, populate, writers }: rec {

  rebuild = {
    useNixOutputMonitor
  }:
  args: target:
    runShell target {}
      (withNixOutputMonitor target useNixOutputMonitor /* sh */ ''
        NIX_PATH=${lib.escapeShellArg target.path} \
        nixos-rebuild ${lib.escapeShellArgs args}
      '');

  runShell = target: {
    allocateTTY ? false
  }: command:
    let
      command' = /* sh */ ''
        ${lib.optionalString target.sudo "sudo"} \
        /bin/sh -c ${lib.escapeShellArg command}
      '';
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
            command'
          ])}
        '';

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
        NIX_PATH=${lib.escapeShellArg target.path} \
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
    operation ? "switch",
    source,
    target,
    useNixOutputMonitor ? "opportunistic"
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
        ${rebuild { inherit useNixOutputMonitor; } ([
          operation
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
    target,
    trace ? false
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
          ${lib.optionalString trace "--show-trace"} \
          '<nixpkgs/nixos>'
    '';
}
