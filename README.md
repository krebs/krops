# krops (krebs operations)

krops is a lightweight toolkit to deploy NixOS systems, remotely or locally.


## Some Features

- store your secrets in [password store](https://www.passwordstore.org/)
- build your system remotely
- minimal overhead (it's basically just `nixos-rebuild switch`!)
- run from custom nixpkgs branch/checkout/fork


## Minimal Example

Create a file named `krops.nix` (name doesn't matter) with following content:

```nix
let
  krops = (import <nixpkgs> {}).fetchgit {
    url = https://cgit.krebsco.de/krops/;
    rev = "v1.17.0";
    sha256 = "150jlz0hlb3ngf9a1c9xgcwzz1zz8v2lfgnzw08l3ajlaaai8smd";
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
krops exports some funtions under `krops.` namely:

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
arguments.  The `sudo` attribute is a boolean and if set to true, then it's
possible to to deploy to targets that disallow sshing in as root, but allow
(preferably passwordless) sudo.
Example:

```nix
pkgs.krops.writeDeploy "deploy" {
  source = /* ... */;
  target = lib.mkTarget "user@host/path" // {
    extraOptions = [
      "-oLogLevel=DEBUG"
    ];
    sudo = true;
  };
}
```
For more details about the `target` attribute, please check the `mkTarget`
function in [lib/default.nix](lib/defaults.nix).

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

Run `nixos-rebuild switch` immediately without building the system
in a dedicated `nix build` step.

### `force` (optional, defaults to false)

Create the sentinel file (`/var/src/.populate`) before syncing the new source.

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


## Source Types

### `derivation`

Nix expression to be built at the target machine.

Supported attributes:

* `text` -
  Nix expression to be built.


### `file`

The file source type transfers local files (and folders) to the target
using [`rsync`](https://rsync.samba.org/).

Supported attributes:

* `path` -
  absolute path to files that should by transfered

* `useChecksum` (optional) -
  boolean that controls whether file contents should be checked to decide
  whether a file has changed.  This is useful when `path` points at files
  with mangled timestamps, e.g. the Nix store.

* `filters` (optional)
  List of filters that should be passed to [`rsync`](https://rsync.samba.org/).
  Filters are specified as attribute sets with the attributes `type` and
  `pattern`.  Supported filter types are `include` and `exclude`.
  Checkout the filter rules section in the
  [rsync manual](https://download.samba.org/pub/rsync/rsync.html)
  for further information.

* `deleteExcluded` (optional)
  boolean that controls whether the excluded directories should be deleted
  if they exist on the target. This is passed to the `--delete-excluded` option
  of rsync. Defaults to `true`.


### `git`

Git sources that will be fetched on the target machine.

Supported attributes:

* `url` -
  URL of the Git repository that should be fetched.

* `ref` -
  Branch / tag / commit that should be fetched.

* `clean.exclude` -
  List of patterns that should be excluded from Git cleaning.

* `shallow` (optional)
  boolean that controls whether only the requested commit ref. should be fetched
  instead of the whole history, to save disk space and bandwith. Defaults to `false`.


### `pass`

The pass source type transfers contents from a local
[password store](https://www.passwordstore.org/) to the target machine.

Supported attributes:

* `dir` -
  absolute path to the password store.

* `name` -
  sub-directory in the password store.


### `pipe`

Executes a local command, capture its stdout, and send that as a file to the
target machine.

Supported attributes:

* `command` -
  The (shell) command to run.

### `symlink`

Symlink to create at the target, relative to the target directory.
This can be used to reference files in other sources.

Supported attributes:

* `target` -
  Content of the symlink.  This is typically a relative path.


## References

- [In-depth example](http://tech.ingolf-wagner.de/nixos/krops/) by [Ingolf Wagner](https://ingolf-wagner.de/)


## Communication

Comments, questions, pull-requests and patches, etc. are very welcome, and can be directed
at:

- IRC: #krebs at freenode
- Mail: [spam@krebsco.de](mailto:spam@krebsco.de)
- Github: https://github.com/krebs/krops/
