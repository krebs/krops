let
  lib = import ../../lib;
in

{ nix, openssh, populate, writeDash, writeJSON }: {

  writeDeploy = name: { source, target }: let
    target' = lib.mkTarget target;
  in
    writeDash name ''
      set -efu
      ${populate { inherit source; target = target'; }}
      ${openssh}/bin/ssh \
          ${target'.user}@${target'.host} -p ${target'.port} \
          nixos-rebuild switch -I ${target'.path}
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
