# Flakes evaluating krops purely, as flakes evaluate by default, and scripts
# running them on the deploying machine.  Their inputs are krops' and
# nixpkgs' sources in the store, without .git, locked as tarballs by their
# hashes, so Nix uses the store paths as they are, without fetching or
# reading them, and the VM shares them with the host's store.
{ pkgs }:

let
  inherit (pkgs) lib;
  inherit (pkgs.stdenv.hostPlatform) system;

  kropsSrc = builtins.path {
    name = "source";
    path = ../.;
    filter = path: type: let name = baseNameOf path; in
      name != ".git" && name != "target" && !lib.hasPrefix "result" name;
  };
  nixpkgsSrc = builtins.path {
    name = "source";
    path = pkgs.path;
    filter = path: type: baseNameOf path != ".git";
  };
  nixpkgsLibSrc = builtins.path {
    name = "source";
    path = pkgs.path + "/lib";
  };

  # A directory with flake.nix, whose inputs are the store paths of inputs
  # by name, not flakes, its lock file, and files, by name.
  flake = { inputs, outputs, files ? {} }: pkgs.runCommand "pure-flake" {
    nativeBuildInputs = [ pkgs.nix ];
  } ''
    mkdir $out
    cat > $out/flake.nix <<'EOF'
    {
      ${lib.concatStrings (lib.mapAttrsToList (name: _: ''
        inputs.${name} = { url = "file:///${name}.tar.gz"; flake = false; };
      '') inputs)}
      outputs = ${outputs};
    }
    EOF
    export HOME=$TMPDIR
    {
      echo '{ "nodes": { "root": { "inputs": {'
      ${lib.concatStringsSep "\necho ,\n" (lib.mapAttrsToList (name: _: ''
        printf '"%s": "%s"' ${name} ${name}
      '') inputs)}
      echo '} }'
      ${lib.concatStrings (lib.mapAttrsToList (name: path: ''
        printf ', "%s": { "flake": false, "locked": { "type": "tarball", "url": "file:///%s.tar.gz", "narHash": "%s" }, "original": { "type": "tarball", "url": "file:///%s.tar.gz" } }\n' \
            ${name} ${name} "$(nix-hash --type sha256 --sri ${path})" ${name}
      '') inputs)}
      echo '}, "root": "root", "version": 7 }'
    } > $out/flake.lock
    ${lib.concatStrings (lib.mapAttrsToList (name: file: ''
      cp ${file} $out/${name}
    '') files)}
  '';

  # A script evaluating what a flake's attribute attr is, purely, printing
  # it, and referring to the store paths of the inputs, so the VM has them.
  evaluate = name: dir: attr: inputs: pkgs.writers.writeDash name ''
    set -efu
    # ${toString (lib.attrValues inputs)}
    exec nix eval --raw ${lib.escapeShellArg "path:${dir}#${attr}"}
  '';

  # krops' lib, from a flake with nixpkgs' lib only.  mkTarget leaves the
  # user and the host null, which pure evaluation can't tell, and the
  # sources of each type evaluate.
  libFlake = let
    inputs = { krops = kropsSrc; lib = nixpkgsLibSrc; };
  in flake {
    inherit inputs;
    outputs = /* nix */ ''
      { krops, lib, ... }: let
        klib = import "''${krops}/lib/with.nix" { lib = import lib; };
        target = klib.mkTarget "";
      in {
        check =
          assert target.user == null && target.host == null;
          assert target.path == "/var/src";
          builtins.toJSON (klib.evalSource [{
            a.derivation = "{}";
            b.file = "/fixtures/alt";
            c.flake = "/fixtures/top";
            d.flake-input = { url = "/fixtures/top"; name = "dep"; };
            e.git = { url = "git://deployer/gitsrc.git"; ref = "HEAD"; };
            f.pass = { dir = "/fixtures/pass"; name = "x"; };
            g.passage.dir = "/fixtures/passage/store";
            h.pipe = "/fixtures/pipe";
            i.symlink = "b";
          }]);
      }
    '';
  };

  # What the host makes of writeDeploy's arguments args, as the flake.
  deployOf = args: import ./pure-deploy.nix {
    krops = kropsSrc;
    nixpkgs = nixpkgsSrc;
    inherit system args;
  };

in {
  lib = evaluate "pure-lib" libFlake "check" { inherit kropsSrc nixpkgsLibSrc; };

  # A script deploying with writeDeploy's arguments args, which have to be
  # JSON, from a flake evaluating it purely.  Building it in the VM would
  # need what building populate needs, so it runs what the host built of
  # the same derivation, failing if pure evaluation makes another.
  deploy = args: let
    args' = builtins.fromJSON (builtins.toJSON args);
    expected = deployOf args';
    dir = flake {
      inputs = { krops = kropsSrc; nixpkgs = nixpkgsSrc; };
      outputs = /* nix */ ''
        { krops, nixpkgs, ... }: {
          deploy = import ./pure-deploy.nix {
            inherit krops nixpkgs;
            system = ${builtins.toJSON system};
            args = builtins.fromJSON (builtins.readFile ./args.json);
          };
        }
      '';
      files = {
        "args.json" = pkgs.writeText "args.json" (builtins.toJSON args');
        "pure-deploy.nix" = ./pure-deploy.nix;
      };
    };
    drvPath = evaluate "pure-deploy-drv" dir "deploy.drvPath" {
      inherit kropsSrc nixpkgsSrc;
    };
  in pkgs.writers.writeDash "pure-deploy" ''
    set -efu
    drv=$(${drvPath})
    if test "$drv" != ${builtins.unsafeDiscardStringContext expected.drvPath}; then
      >&2 printf 'pure evaluation makes %s instead of %s\n' "$drv" \
          ${builtins.unsafeDiscardStringContext expected.drvPath}
      exit 1
    fi
    exec ${expected}
  '';
}
