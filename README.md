# kops (krebs ops)

kops is a lightweigt toolkit to deploy nixos systems, remotely or locally.

fancy features include:
- store your secrets in passwordstore
- build your system remotely
- minimal overhead
- run from custom nixpkgs branch/checkout/fork

minimal example:

create a kops.nix somewhere
```
let
  kops = (import <nixpkgs> {}).fetchgit {
    url = https://cgit.krebsco.de/kops/;
    rev = "3022582ade8049e6ccf18f358cedb996d6716945";
    sha256 = "0wg8d80sxa46z4i7ir79sci2hwmv3qskzqdgksi64p6vazy8vckb";
  };

  lib = import "${kops}/lib";
  pkgs = import "${kops}/pkgs" {};

  source = lib.evalSource [{
    nixpkgs.git = {
      ref = "4b4bbce199d3b3a8001ee93495604289b01aaad3";
      url = https://github.com/NixOS/nixpkgs;
    };
    nixos-config.file = pkgs.writeText "nixos-config" ''
      { config, pkgs, ... }:
      {
        imports =
          [ # Include the results of the hardware scan.
            ./hardware-configuration.nix
          ];

        # Use the GRUB 2 boot loader.
        boot.loader.grub.enable = true;
        boot.loader.grub.version = 2;
        # boot.loader.grub.efiSupport = true;
        # boot.loader.grub.efiInstallAsRemovable = true;
        # boot.loader.efi.efiSysMountPoint = "/boot/efi";
        # Define on which hard drive you want to install Grub.
        boot.loader.grub.device = "/dev/sda"; # or "nodev" for efi only
      }
    '';
  }];
in
  pkgs.kops.writeDeploy "deploy" {
    source = source;
    target = "localhost";
  }
```

and run `nix-build kops.nix`
