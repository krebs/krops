# krops (krebs ops)

krops is a lightweigt toolkit to deploy NixOS systems, remotely or locally.


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

Under the hood, this will make the sources available on the target machine
below `/var/src`, and execute `nixos-rebuild switch -I /var/src`.

## Deployment Target Attribute

The `target` attribute to `writeDeploy` can either be a string or an attribute
set, specifying where to make the sources available, as well as where to run
the deployment.

If specified as string, the format could be described as:
```
[[USER]@]HOST[:PORT][/SOME/PATH]
```

Portions in square brakets are optional.

If the `USER` is the empty string, as in e.g. `@somehost`, then the username
will be obtained by SSH from its configuration files.

If the `target` attribute is an attribute set, then it has to define the attributes
`host`, `path`, `port`, `sudo`, and `user`.  This allows to deploy to targets
that don't allow sshing in as root, but allow (preferably passwordless) sudo:

```nix
pkgs.krops.writeDeploy "deploy" {
  source = /* ... */;
  target = lib.mkTarget "user@host/path" // {
    sudo = true;
  };
}
```

For more details about the `target` attribute, please check the `mkTarget`
function in lib/default.nix.

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
  
* `exclude` (optional)
  List of patterns that should excluded from being synced. The list will be
  passed to the `--exclude` option of [`rsync`](https://rsync.samba.org/).
  Checkout the filter rules section in the [rsync
  manual](https://download.samba.org/pub/rsync/rsync.html) for further
  information.


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
