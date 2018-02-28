let
  lib = import ../../lib // {
    isLocalTarget = let
      origin = lib.mkTarget "";
    in target:
      target.host == origin.host &&
      target.user == origin.user;
  };
in

{ nix, openssh, populate, writeDash, writeJSON }: {

  writeDeploy = name: { source, target }: let
    target' = lib.mkTarget target;
  in
    writeDash name ''
      set -efu

      ${populate}/bin/populate \
          ${target'.user}@${target'.host}:${target'.port}${target'.path} \
        < ${writeJSON "${name}-source.json" source}

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

      ${populate}/bin/populate --force \
          ${target'.path} \
        < ${writeJSON "${name}-source.json" source}

      ${nix}/bin/nix-build \
          -A config.system.build.toplevel \
          -I ${target'.path} \
          --arg modules '[<nixos-config>]' \
          --no-out-link \
          --show-trace \
          '<nixpkgs/nixos/lib/eval-config.nix>'
    '';

}
