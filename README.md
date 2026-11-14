# krops (krebs operations)

krops is a lightweight toolkit to deploy NixOS systems, remotely or locally.


## Some Features

- store your secrets in [password store](https://www.passwordstore.org/)
                     or [passage](https://github.com/FiloSottile/passage)
- build your systems remotely
- minimal overhead (it's basically just `nixos-rebuild switch`!)
- run from custom nixpkgs branch/checkout/fork


## Minimal Example

Create a file named `krops.nix` (name doesn't matter) with following content:

```nix
let
  krops = (import <nixpkgs> {}).fetchgit {
    url = https://cgit.krebsco.de/krops/;
    rev = "v1.25.0";
    sha256 = "07mg3iaqjf1w49vmwfchi7b1w55bh7rvsbgicp2m47gnj9alwdb6";
  };

  lib = import "${krops}/lib";
  pkgs = import "${krops}/pkgs" {};

  source = lib.evalSource [{
    nixpkgs.git = {
      clean.exclude = ["/.version-suffix"];
      ref = "4b4bbce199d3b3a8001ee93495604289b01aaad3";
      url = https://github.com/NixOS/nixpkgs;
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
    target = "root@YOUR_IP_ADDRESS_OR_HOST_NAME_HERE";
  }
```

and run `$(nix-build --no-out-link krops.nix)` to deploy the target machine.


## Requirements

The deploying machine needs Nix and nixpkgs 23.11 or later.  krops builds
[populate](pkgs/populate/README.md), the program that delivers the
sources, with nixpkgs' Rust the first time it's used, which fetches the
program's dependencies from [crates.io](https://crates.io).

The target needs Nix, a POSIX shell, coreutils, findutils, rsync, and
`patch` for sources with `patches`, and a remote target ssh access as
root, or as a user who may use `sudo`.  NixOS has all of them, rsync as
long as `environment.defaultPackages` contains it.  `git` sources need Git on the
target, which NixOS lacks, so the minimal example above installs it.
Features that say so need Nix with flake support (Nix 2.4 or later) on the
machine that uses them.


## Using krops from a flake

krops' flake provides `populate`, `writeDeploy`, and the other functions
described below as `lib.<system>`, and its `lib` directory provides
`evalSource` and `mkTarget`.  `lib/with.nix` is a function taking nixpkgs'
lib, as below; `lib/default.nix` merges it, with `<nixpkgs/lib>`, into
nixpkgs' lib and builtins:

```nix
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.krops.url = "git+https://cgit.krebsco.de/krops";
  inputs.krops.inputs.nixpkgs.follows = "nixpkgs";

  outputs = { self, krops, nixpkgs, ... }: let
    system = "x86_64-linux";
    lib = import "${krops}/lib/with.nix" { inherit (nixpkgs) lib; };
  in {
    apps.${system}.deploy = {
      type = "app";
      program = toString (krops.lib.${system}.writeDeploy "deploy" {
        source = lib.evalSource [{
          nixos-config.file = toString ./configuration.nix;
          nixpkgs.flake-input = { url = toString self; name = "nixpkgs"; };
        }];
        target = "root@YOUR_IP_ADDRESS_OR_HOST_NAME_HERE";
      });
    };
  };
}
```

krops evaluates environment variables and `/etc/hostname`, which pure
evaluation doesn't allow, so deploy with `nix run --impure .#deploy`.

`pkgs.krops` provides the following functions.

## writeDeploy

This will make the sources available on the target machine
below `/var/src`, and execute `nixos-rebuild switch -I /var/src`.


### `target`

The `target` attribute to `writeDeploy` can either be a string or an attribute
set, specifying where to make the sources available, as well as where to run
the deployment.

If specified as string, the format could be described as:
```
[[USER]@]HOST[:PORT][/SOME/PATH]
```

Portions in square brackets are optional.

If the `USER` is the empty string, as in e.g. `@somehost`, then the username
will be obtained by ssh from its configuration files.

If the `target` attribute is an attribute set, then it can specify the
attributes `extraOptions`, `host`, `path`, `port`, `sudo`, and `user`.
The `extraOptions` is a list of strings that get passed to ssh as additional
arguments, one argument per string, so an option and its value are separate
strings, e.g. `[ "-i" "/path/to/key" ]`.  The `sudo` attribute is a boolean and if set to true, then it's
possible to to deploy to targets that disallow sshing in as root, but allow
(preferably passwordless) sudo.
Example:

```nix
pkgs.krops.writeDeploy "deploy" {
  source = /* ... */;
  target = lib.mkTarget "user@host/path" // {
    extraOptions = [
      "-o" "LogLevel=DEBUG"
      ["-i" "/path/to/identity/file"]
    ];
    sudo = true;
  };
}
```
For more details about the `target` attribute, please check the `mkTarget`
function in [lib/with.nix](lib/with.nix).

### `allocateTTY` (optional, defaults to false)

Run `nixos-rebuild` with a terminal, so it shows colours and progress.  On a
remote target, this sets `-t` on the ssh command, which only allocates a
terminal if krops runs in one.  On the local target, `unbuffer` provides one.

### `backup` (optional, defaults to false)

Backup all paths specified in source before syncing new sources.

### `buildTarget` (optional)

If set the evaluation and build of the system will be executed on this host.
`buildTarget` takes the same arguments as target.
Sources will be synced to both `buildTarget` and `target`.
Built packages will be uploaded from the `buildTarget` to `target` directly
This requires the building machine to have ssh access to the target.
To build the system on the same machine, that runs the krops command,
set up a local ssh service and set the build host to localhost.
`nixos-rebuild` can't be told the ports of `buildTarget` and `target`, so their
`port` attributes apply only to syncing the sources.  If both use the same
non-default port, set `NIX_SSHOPTS="-p PORT"` when deploying, so
`nixos-rebuild` uses it as well.

### `crossDeploy` (optional, defaults to false)

Use this option if target host architecture is not the same as the build host
architecture as set by `buildHost` i.e. deploying to aarch64 from a x86_64
machine. Setting this option will disable building & running nix in the wrong
architecture when running `nixos-rebuild` on the deploying machine. It is
required to set `nixpkgs.localSystem.system` in the NixOS configuration to the
architecture of the target host. This option is only useful if the build host
also has remote builders that are capable of producing artifacts for the deploy
architecture.

### `fast` (optional, defaults to false)

Run `nixos-rebuild` immediately without building the system in a dedicated `nix
build` step.

### `flake` (optional)

Name of the source containing the flake to deploy, optionally followed by `#`
and the name of the NixOS configuration, e.g. `"myconf#myhost"`.  If the source
draws inputs from other sources through a generated flake, that flake gets
deployed, see [Flake inputs from sources](pkgs/populate/README.md#flake-inputs-from-sources).  This
makes `nixos-rebuild` use `--flake`, and requires Nix with flake support (Nix
2.4 or later) on the build target.  Without the name of the NixOS
configuration, `nixos-rebuild` uses the host name of the build target.
Without `flake`, `nixos-rebuild` gets `--no-flake` if `/etc/nixos/flake.nix`
exists on the build target, so it deploys `NIX_PATH` instead of that flake.

### `force` (optional, defaults to false)

Create the sentinel file (`/var/src/.populate`) before syncing the new source.

### `operation` (optional, defaults to "switch")

Specifies which `nixos-rebuild` operation to perform.

### `prune` (optional, defaults to false)

Remove everything from the target directory that isn't a source, except
`.populate`, after syncing the sources.  This also removes the garbage
collector roots of the inputs of former `flake` and `flake-input` sources in
`.populate/flake-inputs/<name>`, so the garbage collector can collect what
they delivered.  Don't use it if the target directory contains anything else
worth keeping, or if several deployments with different sources share it.

### `useNixOutputMonitor` (optional, defaults to `"opportunistic"`)

Specifies when to pipe `nixos-rebuild`'s output to
[nom](https://github.com/maralorn/nix-output-monitor).

Supported values:

* `"opportunistic"` (default) -
  Use `nom` only if it is present on the target machine.

* `"optimistic"` -
  Use `nom`, assuming it is present on the target machine.

* `"pessimistic"` -
  Use `nom` via `nix-shell` on the target machine.

* `true` -
  Use `nom`.
  If it is not present on the target machine, then use it via `nix-shell`.

* `false` -
  Don't use `nom`

## writeTest

Very similiar to writeDeploy, but just builds the system on the target without
activating it.

This basically makes the sources available on the target machine
below `/var/src`, and executes `NIX_PATH=/var/src nix-build -A system '<nixpkgs/nixos>'`.

### `target`

[see `writeDeploy`](#writeDeploy)

### `backup` (optional, defaults to false)

[see `writeDeploy`](#writeDeploy)

### `force` (optional, defaults to false)

[see `writeDeploy`](#writeDeploy)

### `prune` (optional, defaults to false)

[see `writeDeploy`](#writeDeploy)

### `trace` (optional, defaults to false)

run nix-build with `--show-trace`

## writeCommand

This can be used to run other commands than `nixos-rebuild` or pre/post build hooks.

### `command`

A function which takes the targetPath as an attribute.
Example to activate/deactivate a swapfile before/after build:

```nix
pkgs.krops.writeCommand "deploy-with-swap" {
  source = source;
  target = "root@YOUR_IP_ADDRESS_OR_HOST_NAME_HERE";
  command = targetPath: ''
    swapon /var/swapfile
    nixos-rebuild -I ${targetPath} switch
    swapoff /var/swapfile
  '';
}
```

### `target`

[see `writeDeploy`](#writeDeploy)

### `backup` (optional, defaults to false)

[see `writeDeploy`](#writeDeploy)

### `force` (optional, defaults to false)

[see `writeDeploy`](#writeDeploy)

### `prune` (optional, defaults to false)

[see `writeDeploy`](#writeDeploy)

### `allocateTTY` (optional, defaults to false)

whether the ssh session should do a pseudo-terminal allocation.
sets `-t` on the ssh command.

## The target directory

populate owns the target directory, and doesn't change anything outside it.
[populate's README](pkgs/populate/README.md#the-target-directory) says what
that means.


## Source Types

`lib.evalSource` turns sources, written in Nix, into what `pkgs.populate`
passes to populate.  [populate's
README](pkgs/populate/README.md#source-types) describes the source types:
`derivation`, `file`, `flake`, `flake-input`, `git`, `pass`, `passage`,
`pipe`, and `symlink`.


## Flake inputs from sources

Sources can draw inputs of the flakes they contain from other sources, as
[populate's README](pkgs/populate/README.md#flake-inputs-from-sources)
describes.  `writeDeploy`'s `flake` uses a source's generated flake
automatically.


## Tests

`tests/` contains NixOS VM tests for krops, using the VM machinery and the
scenarios of [populate's tests](pkgs/populate/README.md#tests): `deploy`,
for the arguments `writeDeploy` passes to `nixos-rebuild`, which a stand-in
records, and `populate`, for `pkgs.populate`, running populate's scenarios
that expect populate to refuse its arguments, which `pkgs.populate` does
during evaluation, and those of populate's smoke test.  The tests require
KVM and nixpkgs with `pkgs.testers.runNixOSTest` (23.05 or later), and use
`<nixpkgs>` by default.

```sh
nix-build tests                   # all tests, except the exhaustive ones
nix-build tests -A deploy         # the test of writeDeploy
nix-build tests -A exhaustive     # all exhaustive tests
nix-build tests -A smoke          # a few scenarios of each, in one VM
nix-build tests -A only --argstr only 'lock-hooks-.*'  # scenarios by name
```

`-A only` selects from all of populate's scenarios and krops' own, all
running through `pkgs.populate`.


## References

- [In-depth example](http://tech.ingolf-wagner.de/nixos/krops/) by [Ingolf Wagner](https://ingolf-wagner.de/)


## Communication

Comments, questions, pull-requests and patches, etc. are very welcome, and can be directed
at:

- IRC: #krebs at hackint
- Mail: [spam@krebsco.de](mailto:spam@krebsco.de)
- Github: https://github.com/krebs/krops/
