let
  lib = import ../../lib;
in

{ nix, openssh, populate, writeDash, writeJSON }: let

  populate' = name: { source, target }:
    writeDash "${name}-populate" ''
      set -efu
      source=${writeJSON "${name}-source.json" source}
      target=${target.user}@${target.host}:${target.port}${target.path}
      exec ${populate}/bin/populate "$target" < "$source"
    '';

in {

  writeDeploy = name: { source, target }: let
    target' = lib.mkTarget target;
  in
    writeDash name ''
      set -efu
      ${populate' name { inherit source; target = target'; }}
      ${openssh}/bin/ssh \
          ${target'.user}@${target'.host} -p ${target'.port} \
          nixos-rebuild switch -I ${target'.path}
    '';

  writePopulate = name: { source, target }:
    populate' name {
      inherit source;
      target = lib.mkTarget target;
    };

  writeTest = name: { source, target }: let
    target' = lib.mkTarget target;
  in
    assert lib.isLocalTarget target';
    writeDash name ''
      set -efu
      ${populate' name { inherit source; target = target'; }}
      ${nix}/bin/nix-build \
          -A config.system.build.toplevel \
          -I ${target'.path} \
          --arg modules '[<nixos-config>]' \
          --no-out-link \
          --show-trace \
          '<nixpkgs/nixos/lib/eval-config.nix>'
    '';

}
