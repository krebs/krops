let
  lib = import ../../lib;
in

{ exec, nix, openssh, populate, writeDash }: rec {

  build = target:
    remoteCommand target (lib.concatStringsSep " " [
      "nix build"
      "-I ${lib.escapeShellArg target.path}"
      "--no-link -f '<nixpkgs/nixos>'"
      "config.system.build.toplevel"
    ]);

  rebuild = args: target:
    remoteCommand target "nixos-rebuild -I ${lib.escapeShellArg target.path} ${
      lib.concatMapStringsSep " " lib.escapeShellArg args
    }";

  remoteCommand = target: command:
    exec "build.${target.host}" rec {
      filename = "${openssh}/bin/ssh";
      argv = lib.flatten [
        filename
        (lib.optionals (target.user != "") ["-l" target.user])
        "-p" target.port
        "-t"
        target.host
        (if target.sudo then "sudo ${command}" else command)
      ];
    };

  writeCommand = name: {
    command ? (targetPath: "echo ${targetPath}"),
    backup ? false,
    force ? false,
    source,
    target
  }: let
    target' = lib.mkTarget target;
  in
    writeDash name ''
      set -efu
      ${populate { inherit backup force source; target = target'; }}
      ${remoteCommand target' (command target'.path)}
    '';

  writeDeploy = name: {
    backup ? false,
    buildTarget ? null,
    fast ? false,
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
    writeDash name ''
      set -efu
      ${lib.optionalString (buildTarget' != target')
        (populate { inherit backup force source; target = buildTarget'; })}
      ${populate { inherit backup force source; target = target'; }}
      ${lib.optionalString (! fast) ''
        ${rebuild ["dry-build"] buildTarget'}
        ${build buildTarget'}
      ''}
      ${rebuild ([
        "switch"
      ] ++ lib.optionals (buildTarget' != target') [
        "--build-host" "${buildTarget'.user}@${buildTarget'.host}"
        "--target-host" "${target'.user}@${target'.host}"
      ]) buildTarget'}
    '';

  writeTest = name: {
    backup ? false,
    force ? false,
    source,
    target
  }: let
    target' = lib.mkTarget target;
  in
    assert lib.isLocalTarget target';
    writeDash name ''
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
