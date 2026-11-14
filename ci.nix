let
  krops = ./.;

  pkgs = import "${krops}/pkgs" {};
  klib = import "${krops}/lib/with.nix" { inherit (pkgs) lib; };

  source = klib.evalSource [{
    nixos-config.file = pkgs.writeText "nixos-config" ''
      { pkgs, ... }: {

        fileSystems."/" = { device = "/dev/sda1"; };
        boot.loader.systemd-boot.enable = true;
        services.openssh.enable = true;
        environment.systemPackages = [ pkgs.git ];
      }
    '';
    nixpkgs.symlink = toString <nixpkgs>;
  }];
in {
  test = pkgs.krops.writeTest "test" {
    force = true;
    source = source;
    target = "${builtins.getEnv "HOME"}/krops-test";
  };
}
