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
      "-o" "LogLevel=DEBUG"
    ];
    sudo = true;
  };
}
```
For more details about the `target` attribute, please check the `mkTarget`
function in [lib/default.nix](lib/default.nix).

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

Run `nixos-rebuild` immediately without building the system in a dedicated `nix
build` step.

### `flake` (optional)

Name of the source containing the flake to deploy, optionally followed by `#`
and the name of the NixOS configuration, e.g. `"myconf#myhost"`.  If the source
draws inputs from other sources, its generated flake gets deployed, see
[Flake inputs from sources](#flake-inputs-from-sources).  This makes
`nixos-rebuild` use `--flake`, and requires Nix with flake support (Nix 2.4 or
later) on the build target.  Without the name of the NixOS configuration,
`nixos-rebuild` uses the host name of the build target.

### `force` (optional, defaults to false)

Create the sentinel file (`/var/src/.populate`) before syncing the new source.

### `operation` (optional, defaults to "switch")

Specifies which `nixos-rebuild` operation to perform.

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

### `allocateTTY` (optional, defaults to false)

whether the ssh session should do a pseudo-terminal allocation.
sets `-t` on the ssh command.

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
  absolute path to files that should by transferred.

* `useChecksum` (optional) -
  boolean that controls whether file contents should be checked to decide
  whether a file has changed.  This is useful when `path` points at files
  with mangled timestamps, e.g. the Nix store.

  The default value is `true` if `path` is a derivation, and `false` otherwise.

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

* `inputs` (optional) -
  inputs of the flake in this source to draw from other sources, see
  [Flake inputs from sources](#flake-inputs-from-sources).


### `flake`

The flake source type delivers a flake, or one of its locked inputs, to the
target.  The flake gets archived locally using `nix flake archive`, the
selected input and its own inputs get copied into the target's Nix store using
`nix copy`, and the target path becomes a symlink to the input's store path,
registered as garbage collector root.  The input's own inputs get garbage
collector roots in `.populate/flake-inputs/<name>`, which turns the sentinel
file into a directory.

Because the target path points at the store path named by the flake's lock
file, it can be used in `NIX_PATH` as well as by flakes evaluated on the
target, without network access.

Supported attributes:

* `flake` -
  flake reference, e.g. the absolute path of a directory containing a
  `flake.nix`.  Its lock file is used as is; populating fails if the lock
  file needs to be updated.

* `input` (optional) -
  name of the input to deliver.  Inputs of inputs are separated by `/`,
  e.g. `stockholm/nixpkgs`.  If omitted, the flake itself gets delivered,
  which includes only files tracked by Git.  Use a `file` source for work
  trees with untracked files.

* `fetchOnTarget` (optional) -
  boolean that controls whether the target fetches the input itself instead
  of receiving it from the deploying machine.  The target then uses the
  arguments recorded in the lock file, so inputs that refer to local paths of
  the deploying machine can't be fetched this way.  This requires `input`,
  and Nix with flake support (Nix 2.4 or later) on the target.  Defaults to
  `false`.

* `inputs` (optional) -
  inputs of the flake in this source to draw from other sources, see
  [Flake inputs from sources](#flake-inputs-from-sources).

Instead of an attribute set, the flake reference can be given as a string.

The flake commands on the deploying machine run using krops' own Nix, so
flakes don't need to be enabled there.  Without `fetchOnTarget`, the target
only needs `nix-store`.  Because the copied store paths aren't signed, the
target user must be allowed to import them, i.e. be `root` or a trusted user,
and targets using `sudo` aren't supported.

Example:

```nix
{
  nixpkgs.flake = {
    flake = toString ./.;
    input = "nixpkgs";
  };
}
```


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

* `inputs` (optional) -
  inputs of the flake in this source to draw from other sources, see
  [Flake inputs from sources](#flake-inputs-from-sources).


### `pass`

The pass source type transfers contents from a local
[password store](https://www.passwordstore.org/) to the target machine.

Supported attributes:

* `dir` -
  absolute path to the password store.

* `name` -
  sub-directory in the password store.


### `passage`

The passage source type decrypts files from a local
[passage store](https://github.com/FiloSottile/passage)
and transfers them to the target using
[`rsync`](https://rsync.samba.org/).

Supported attributes:

* `dir` -
  Path to the passage store.
  For a partial transfer, this may point to a subdirectory.
  Example: `~/.passage/store/hosts/MYHOSTNAME`

* `identities_file` (optional) -
  Path to the identities file.
  Defaults to `~/.passage/identities`.

* `age` (optional) -
  Path of the age binary.
  Defaults to `age` (absolute path gets resolved using `passage`'s search path.)


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

* `inputs` (optional) -
  inputs of the flake in this source to draw from other sources, see
  [Flake inputs from sources](#flake-inputs-from-sources).


## Flake inputs from sources

Sources of type `file`, `flake`, `git`, and `symlink` can declare which inputs
of the flake they contain get drawn from other sources, in the style of
`flake.nix`, where `follows` names a source instead of an input.  This makes
flakes on the target use what krops delivers there, much like `NIX_PATH` does
for Nix expressions.

```nix
{
  nixpkgs.flake = {
    flake = toString ./.;
    attribute = "nixpkgs";
  };
  crate2nix.flake = {
    flake = "github:nix-community/crate2nix";
    inputs.nixpkgs.follows = "nixpkgs";
  };
  myconf.file = {
    path = toString ./.;
    inputs = {
      crate2nix.follows = "crate2nix";
      stockholm.inputs.nixpkgs.follows = "nixpkgs";
    };
  };
}
```

For each source that draws inputs from other sources, populate generates a
flake in `.populate/flakes/<name>`, which re-exports the outputs of the flake
in the source, with those inputs drawn from the other sources.  The source
itself stays as it is, so `NIX_PATH` still refers to it.  When a generated
flake draws an input from a source that has a generated flake itself, it uses
that one, so in the example above, myconf's crate2nix uses nixpkgs from the
`nixpkgs` source as well.  `writeDeploy`'s `flake` parameter uses a source's
generated flake automatically.

Sources in a Git work tree are referred to as `git+file:` (with submodules if
there are any), all other sources as `path:`, with symlinks resolved.
Generated flakes get locked on every run, so their lock files match the
sources, and get removed once their sources no longer draw inputs from other
sources.  This requires Nix with flake support (Nix 2.4 or later) on the
target.  Populating fails if a source that draws inputs from other sources
contains no `flake.nix`.  Sources that inputs get drawn from don't need to be
flakes, as long as the inputs drawing from them are declared with
`flake = false`.


## References

- [In-depth example](http://tech.ingolf-wagner.de/nixos/krops/) by [Ingolf Wagner](https://ingolf-wagner.de/)


## Communication

Comments, questions, pull-requests and patches, etc. are very welcome, and can be directed
at:

- IRC: #krebs at hackint
- Mail: [spam@krebsco.de](mailto:spam@krebsco.de)
- Github: https://github.com/krebs/krops/
