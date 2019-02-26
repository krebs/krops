# krops (krebs ops)

krops is a lightweigt toolkit to deploy NixOS systems, remotely or locally.


## Some Features

- store your secrets in [password store](https://www.passwordstore.org/)
- build your system remotely
- minimal overhead (it's basically just `nixos-rebuild switch`!)
- run from custom nixpkgs branch/checkout/fork


## Minimal Example

Create a file named `krops.nix` (name doesn't matter) with following content:

```
let
  krops = (import <nixpkgs> {}).fetchgit {
    url = https://cgit.krebsco.de/krops/;
    rev = "3022582ade8049e6ccf18f358cedb996d6716945";
    sha256 = "0k3zhv2830z4bljcdvf6ciwjihk2zzcn9y23p49c6sba5hbsd6jb";
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

Under the hood, this will make the sources available on the target machine
below `/var/src`, and execute `nixos-rebuild switch -I /var/src`.


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


### `git`

Git sources that will be fetched on the target machine.

Supported attributes:

* `url` -
  URL of the Git repository that should be fetched.

* `ref` -
  Branch / tag / commit that should be fetched.

* `clean.exclude` -
  List of patterns that should be excluded from Git cleaning.


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

Comments, questions, pull-requests, etc. are very welcome, and can be directed
at:

- IRC: #krebs at freenode
- Mail: [spam@krebsco.de](mailto:spam@krebsco.de)
