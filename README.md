# krops (krebs ops)

krops is a lightweigt toolkit to deploy nixos systems, remotely or locally.

fancy features include:
- store your secrets in passwordstore
- build your system remotely
- minimal overhead
- run from custom nixpkgs branch/checkout/fork

minimal example:

create a krops.nix somewhere
```
let
  #krops = ./.;
  krops = builtins.fetchGit {
    url = https://cgit.krebsco.de/krops/;
    ref = "master";
  };

  lib = import "${krops}/lib";
  pkgs = import "${krops}/pkgs" {};

  source = lib.evalSource [{
    nixpkgs.git = {
      ref = "origin/nixos-18.03";
      url = https://github.com/NixOS/nixpkgs-channels;
    };
    nixos-config.file = toString (pkgs.writeText "nixos-config" ''
      { pkgs, ... }: {

        fileSystems."/" = { device = "/dev/sda1"; };
        boot.loader.systemd-boot.enable = true;
        services.openssh.enable = true;
        environment.systemPackages = [ pkgs.git ];
        users.users.root.openssh.authorizedKeys.keys = [
          "ssh-rsa ADD_YOUR_OWN_PUBLIC_KEY_HERE user@localhost"
        ];
      }
    '');
  }];
in
  pkgs.krops.writeDeploy "deploy" {
    source = source;
    target = "root@192.168.56.101";
  }
```

and run `$(nix-build krops.nix)`. This results in a script which deploys the machine via ssh & rsync on the target machine.
