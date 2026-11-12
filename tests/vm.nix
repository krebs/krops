# Runs scenarios in a NixOS VM test with two machines: deployer, which runs
# populate, and target, which it deploys to via ssh.  Local scenarios deploy
# to deployer itself.
{ pkgs, name, scenarios, gitHead }:

let
  inherit (pkgs) lib;

  sshKeys = import (pkgs.path + "/nixos/tests/ssh-keys.nix") pkgs;

  # The scenarios as JSON, with scripts as files.
  plan = pkgs.writeText "krops-test-${name}.json" (builtins.toJSON (map
    (scenario: scenario // {
      prepare = pkgs.writeText "prepare" scenario.prepare;
      phases = map
        (phase: phase // {
          check = pkgs.writeText "check" phase.check;
          mutate =
            if phase.mutate == null then null
            else pkgs.writeText "mutate" phase.mutate;
        })
        scenario.phases;
    })
    scenarios));

  common = { pkgs, ... }: {
    # The plan refers to all scripts the scenarios run.  Being part of the
    # system, they survive the scenarios collecting garbage.
    system.extraDependencies = [ plan "${./fixtures.sh}" ];
    nix.settings.substituters = lib.mkForce [];
    environment.systemPackages = [
      pkgs.git
      pkgs.rsync
      (pkgs.writeScriptBin "nixos-rebuild" (builtins.readFile ./nixos-rebuild.sh))
    ];
    # The stand-in replaces nixos-rebuild.
    system.disableInstallerTools = true;
    # Only warnings and errors on the console, which ends up in the log.
    services.journald.extraConfig = lib.mkAfter "MaxLevelConsole=warning";
    boot.initrd.systemd.contents."/etc/systemd/journald.conf".text =
      lib.mkAfter "MaxLevelConsole=warning";
    boot.consoleLogLevel = lib.mkForce 4;
    # Neither probing BIOS disk information, nor iPXE option ROMs, which
    # network boot would need, nor systemd-oomd, which warns about missing
    # swap.
    boot.kernelParams = lib.optional pkgs.stdenv.hostPlatform.isx86 "edd=off";
    virtualisation.qemu.options = [ "-global virtio-net-pci.romfile=" ];
    systemd.oomd.enable = false;
    virtualisation.memorySize = 2048;
    virtualisation.diskSize = 4096;
  };

in pkgs.testers.runNixOSTest {
  name = "krops-${name}";

  globalTimeout = 4 * 60 * 60;

  nodes.deployer = { pkgs, ... }: {
    imports = [ common ];
    environment.systemPackages = [
      pkgs.age pkgs.gnupg pkgs.pass pkgs.passage
    ];
    networking.firewall.allowedTCPPorts = [ 8000 9418 ];
    programs.ssh.extraConfig = ''
      StrictHostKeyChecking no
      UserKnownHostsFile /dev/null
      LogLevel ERROR
    '';
    systemd.services.fixtures-http = {
      wantedBy = [ "multi-user.target" ];
      preStart = "mkdir -p /fixtures/www";
      serviceConfig.ExecStart =
        "${pkgs.python3}/bin/python3 -m http.server 8000 --directory /fixtures/www";
    };
    systemd.services.fixtures-git = {
      wantedBy = [ "multi-user.target" ];
      preStart = "mkdir -p /fixtures/git";
      serviceConfig.ExecStart =
        "${pkgs.git}/bin/git daemon --reuseaddr --export-all --base-path=/fixtures/git";
    };
  };

  nodes.target = { ... }: {
    imports = [ common ];
    services.openssh.enable = true;
    users.users.root.openssh.authorizedKeys.keys = [ sshKeys.snakeOilPublicKey ];
    users.users.deploy = {
      isNormalUser = true;
      extraGroups = [ "wheel" ];
      openssh.authorizedKeys.keys = [ sshKeys.snakeOilPublicKey ];
    };
    security.sudo.wheelNeedsPassword = false;
  };

  testScript = /* python */ ''
    import json

    plan = json.load(open("${plan}"))
    nodes = {"deployer": deployer, "target": target}


    # Runs a command, logging its output only if it fails.
    def run(node, command):
        status, out = node.execute(f"{command} 2>&1")
        if status != 0:
            raise Exception(f"{command} fails:\n{out}")


    start_all()
    deployer.wait_for_unit("fixtures-http.service")
    deployer.wait_for_unit("fixtures-git.service")
    deployer.wait_for_open_port(8000)
    deployer.wait_for_open_port(9418)
    target.wait_for_unit("sshd.service")
    target.wait_for_open_port(22)

    with subtest("setup"):
        run(deployer, "install -Dm600 ${sshKeys.snakeOilPrivateKey} /root/.ssh/id_ecdsa")
        run(deployer, "ssh root@target true")
        run(deployer, "ssh deploy@target sudo true")
        run(deployer, "HOME=/root sh ${./fixtures.sh} http://deployer:8000 ${gitHead}")

    failed = []
    for scenario in plan:
        node = nodes[scenario["node"]]
        try:
            with subtest(scenario["name"]):
                run(node, f"sh {scenario['prepare']}")
                for i, phase in enumerate(scenario["phases"]):
                    status, out = deployer.execute(f"HOME=/root {phase['populate']} 2>&1")
                    if phase["expect"] is None:
                        if status != 0:
                            raise Exception(f"populate {i} fails:\n{out}")
                    elif status == 0 or phase["expect"] not in out:
                        raise Exception(
                            f"populate {i} doesn't fail with {phase['expect']!r}:\n{out}"
                        )
                    run(node, f"KROPS_TEST_GC=1 sh {phase['check']}")
                    if phase["mutate"] is not None:
                        run(node, f"sh {phase['mutate']}")
        except Exception as e:
            print(f"scenario {scenario['name']} fails: {e}")
            failed.append(scenario["name"])

    if failed:
        raise Exception(f"{len(failed)} scenarios fail: {' '.join(failed)}")
  '';
}
