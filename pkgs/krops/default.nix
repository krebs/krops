let
  lib = import ../../lib;
in

{ exec, nix, openssh, populate, writeDash }: rec {

  rebuild = target:
    exec "rebuild.${target.host}" rec {
      filename = "${openssh}/bin/ssh";
      argv = [
        filename
        "-l" target.user
        "-p" target.port
        target.host
        "nixos-rebuild switch -I ${lib.escapeShellArg target.path}"
      ];
    };

  writeDeploy = name: { source, target }: let
    target' = lib.mkTarget target;
  in
    writeDash name ''
      set -efu
      ${populate { inherit source; target = target'; }}
      ${rebuild target'}
    '';

  writeTest = name: { source, target }: let
    target' = lib.mkTarget target;
  in
    assert lib.isLocalTarget target';
    writeDash name ''
      set -efu
      ${populate { inherit source; target = target'; }}
      ${nix}/bin/nix-build \
          -A system \
          -I ${target'.path} \
          --no-out-link \
          --show-trace \
          '<nixpkgs/nixos>'
    '';

}
