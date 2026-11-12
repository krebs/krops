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


## Using krops from a flake

krops' flake provides `populate`, `writeDeploy`, and the other functions
described below as `lib.<system>`, and its `lib` directory provides
`evalSource` and `mkTarget`:

```nix
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.krops.url = "git+https://cgit.krebsco.de/krops";
  inputs.krops.inputs.nixpkgs.follows = "nixpkgs";

  outputs = { self, krops, ... }: let
    system = "x86_64-linux";
    lib = import "${krops}/lib";
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

krops evaluates `<nixpkgs/lib>`, environment variables, and `/etc/hostname`,
which pure evaluation doesn't allow, so deploy with `nix run --impure .#deploy`.
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
deployed, see [Flake inputs from sources](#flake-inputs-from-sources).  This
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

* `insecureLinks` (optional) -
  what to do if rsync can't read `.rsync-filter` files in `path`.  rsync 3.5.0
  and later open them more strictly than the files they transfer, and ignore
  the ones they can't open, e.g. because a directory on the way may be
  entered but not read, like a home directory with mode 711, or because a
  symlink on the way belongs to neither root nor the user deploying.  By
  default, with `null`, populating fails with an error naming the file.  With
  `true`, rsync reads such files anyway (`--insecure-links`); with `false`,
  rsync syncs without them.  Both print a warning.  Older versions of rsync
  aren't affected.

* `inputs` (optional) -
  inputs of the flake in this source to draw from other sources, see
  [Flake inputs from sources](#flake-inputs-from-sources).

* `rewriteLock` (optional) -
  boolean that controls whether inputs get drawn from other sources by
  rewriting the lock file of the flake in this source, or else through a
  generated flake, see [Flake inputs from sources](#flake-inputs-from-sources).
  Defaults to `true`.


### `flake`

The flake source type delivers a flake to the target.  The flake gets
archived locally using `nix flake archive`, which includes only files tracked
by Git, so use a `file` source for work trees with untracked files.  The
flake and its inputs get copied into the target's Nix store using `nix copy`,
and the target path becomes a symlink to the flake's store path, registered
as garbage collector root.  For flakes in a subdirectory, e.g.
`git+file:/src/mono?dir=sub`, the symlink points at that subdirectory of the
store path.  The inputs get garbage collector roots in
`.populate/flake-inputs/<name>`, which turns the sentinel file into a
directory.

Supported attributes:

* `fetchOnTarget` (optional) -
  boolean that controls whether the target fetches the flake's inputs itself
  instead of receiving them from the deploying machine.  The target then uses
  the arguments recorded in the lock file, so inputs that refer to local paths
  can only be fetched if the target has these paths as well; populating fails
  otherwise, naming the input.  If the flake reference names a scheme that
  doesn't refer to the deploying machine, e.g. `github:`, the target handles
  the flake entirely on its own, and the deploying machine doesn't fetch it.
  Otherwise the target fetches the flake itself as well if its locked
  reference doesn't refer to the deploying machine, e.g. for indirect
  references resolving to `github:` flakes, or else the flake gets
  transferred using `rsync`, unless the target's Nix store has it already,
  and added to the target's Nix store, where it gets the same store path as
  on the deploying machine.  This requires Nix with flake support (Nix 2.4 or
  later) on the target, and works for targets using `sudo`.  Defaults to
  `false`.

* `url` -
  flake reference, e.g. the absolute path of a directory containing a
  `flake.nix`.  Its lock file is used as is; populating fails if the lock
  file needs to be updated.

* `inputs` (optional) -
  inputs of the flake in this source to draw from other sources, see
  [Flake inputs from sources](#flake-inputs-from-sources).

* `materialize` (optional) -
  boolean that controls whether the target path becomes a writable copy
  instead of a link into the store.  The copy gets made again only if what
  it derives from changes: the delivered store path, the patches, or which
  inputs get drawn from which sources.  Until then, changes made to it on the
  target stay.  Nix copies it into the store whenever evaluating a flake
  changed it, which is noticeable for big flakes like nixpkgs.  For a flake
  in a subdirectory, only that subdirectory gets copied.  Defaults to
  `false`.

* `patches` (optional) -
  list of paths of patches on the deploying machine, which get applied in
  order with `patch -p1` on the target, in the directory the target path
  shows.  Populating fails if a patch doesn't apply.  Defaults to `[]`.

* `rewriteLock` (optional) -
  boolean that controls whether inputs get drawn from other sources by
  rewriting the lock file of the flake in this source, or else through a
  generated flake, see [Flake inputs from sources](#flake-inputs-from-sources).
  Defaults to `true`.

Instead of an attribute set, the flake reference can be given as a string.

The flake commands on the deploying machine run using krops' own Nix, so
flakes don't need to be enabled there.  Without `fetchOnTarget`, the target
only needs `nix-store`.  Because the copied store paths aren't signed, the
target user must be allowed to import them, i.e. be `root` or a trusted user,
and targets using `sudo` aren't supported.


### `flake-input`

The flake-input source type delivers an input of a flake, as recorded in the
flake's lock file, to the target.  This makes the lock file of a flake the
single place that pins, e.g., nixpkgs, for flakes as well as for `NIX_PATH`.
It works like the `flake` source type, but delivers the selected input
instead of the flake, so the target path becomes a symlink to the input's
store path.  The inputs that the input's own lock file pins, which evaluating
the input needs, get delivered as well, with garbage collector roots in
`.populate/flake-inputs/<name>`.  An input without a lock file comes without
its inputs, because locking it would change it.

Because the target path points at the store path named by the lock file, it
can be used in `NIX_PATH` as well as by flakes evaluated on the target,
without network access.

Supported attributes:

* `url` -
  flake reference of the flake whose input gets delivered, e.g. the absolute
  path of a directory containing a `flake.nix`.  Its lock file is used as is;
  populating fails if the lock file needs to be updated.

* `name` -
  name of the input to deliver.  Inputs of inputs are separated by `/`,
  e.g. `stockholm/nixpkgs`, and resolved as the flake's lock file resolves
  them, so an input that follows another one names the other one.

* `fetchOnTarget` (optional) -
  boolean that controls whether the target fetches the input itself instead
  of receiving it from the deploying machine.  The target then uses the
  arguments recorded in the lock file, so inputs that refer to local paths
  can only be fetched if the target has these paths as well; populating fails
  otherwise, naming the input.  This requires Nix with flake support (Nix 2.4
  or later) on the target, and works for targets using `sudo`.  Defaults to
  `false`.

* `inputs` (optional) -
  inputs of the flake in this source to draw from other sources, see
  [Flake inputs from sources](#flake-inputs-from-sources).

* `materialize` (optional) -
  boolean that controls whether the target path becomes a writable copy
  instead of a link into the store.  The copy gets made again only if what
  it derives from changes: the delivered store path, the patches, or which
  inputs get drawn from which sources.  Until then, changes made to it on the
  target stay.  Nix copies it into the store whenever evaluating a flake
  changed it, which is noticeable for big flakes like nixpkgs.  For a flake
  in a subdirectory, only that subdirectory gets copied.  Defaults to
  `false`.

* `patches` (optional) -
  list of paths of patches on the deploying machine, which get applied in
  order with `patch -p1` on the target, in the directory the target path
  shows.  Populating fails if a patch doesn't apply.  Defaults to `[]`.

* `rewriteLock` (optional) -
  boolean that controls whether inputs get drawn from other sources by
  rewriting the lock file of the flake in this source, or else through a
  generated flake, see [Flake inputs from sources](#flake-inputs-from-sources).
  Defaults to `true`.

Without `fetchOnTarget`, the same requirements as for the `flake` source type
apply.

Example:

```nix
{
  nixpkgs.flake-input = {
    url = toString ./.;
    name = "nixpkgs";
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

* `rewriteLock` (optional) -
  boolean that controls whether inputs get drawn from other sources by
  rewriting the lock file of the flake in this source, or else through a
  generated flake, see [Flake inputs from sources](#flake-inputs-from-sources).
  Defaults to `true`.


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

Sources of type `file`, `flake`, `flake-input`, `git`, and `symlink` can
declare which inputs of the flake they contain get drawn from other sources,
in the style of `flake.nix`, where `follows` names a source instead of an
input.  This makes flakes on the target use what krops delivers there, much
like `NIX_PATH` does for Nix expressions.

```nix
{
  nixpkgs.flake-input = {
    url = toString ./.;
    name = "nixpkgs";
  };
  crate2nix.flake = {
    url = "github:nix-community/crate2nix";
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

Populate rewrites the lock file of the flake in each source that draws
inputs from other sources, using `nix flake lock --override-input`, so the
flake in the source itself uses the other sources.  `file` and `git` sources
get their lock file rewritten in place.  `flake` and `flake-input` sources
get delivered as a copy with the rewritten lock file, which gets added to the
store, unless materialized, so the target path links to that instead of the
delivered store path, as it does for patched ones.  A source drawing an input
from a source that draws inputs itself uses that source as rewritten, so in
the example above, myconf's crate2nix uses nixpkgs from the `nixpkgs` source as
well.

With `rewriteLock = false`, and for `symlink` sources, which point at other
sources, the source stays as it is, and populate generates a flake in
`.populate/flakes/<name>` instead, which re-exports the outputs of the flake
in the source, with those inputs drawn from the other sources.  A source
drawing an input from a source with a generated flake uses that flake.
`writeDeploy`'s `flake` parameter uses a source's generated flake
automatically.

Sources in a Git work tree are referred to as `git+file:` (with submodules if
there are any), all other sources as `path:`, with symlinks resolved.  Lock
files get rewritten or generated on every run, so they match the sources.
Copies of `flake` and `flake-input` sources get made again only if the
delivered store path, the patches, or the sources they draw inputs from
change.  Generated flakes and copies get removed once their sources no longer
need them.  This requires Nix with flake support (Nix 2.4 or later) on the
target.  Populating fails if a source that draws inputs from other sources
contains no `flake.nix`.  Sources that inputs get drawn from don't need to be
flakes, as long as the inputs drawing from them are declared with
`flake = false`.


## Tests

`tests/` contains NixOS VM tests for populate: one test per source type, one
for features spanning sources, such as flake inputs from sources, one for edge
cases of flakes, such as unusual lock files, and one for the arguments
`writeDeploy` passes to `nixos-rebuild`.  The tests deploy every combination
of a source type's options, except for patches, which the features test
covers, to the deploying machine itself, to a remote target
as `root`, and to a remote target using `sudo`, and check the result after
deploying and after deploying again.
The tests require KVM and nixpkgs with `pkgs.testers.runNixOSTest`
(23.05 or later), and use `<nixpkgs>` by default.

```sh
nix-build tests            # all tests
nix-build tests -A flake   # the test for one source type
nix-build tests -A jq      # populate's jq programs for flakes, without VMs
```


## References

- [In-depth example](http://tech.ingolf-wagner.de/nixos/krops/) by [Ingolf Wagner](https://ingolf-wagner.de/)


## Communication

Comments, questions, pull-requests and patches, etc. are very welcome, and can be directed
at:

- IRC: #krebs at hackint
- Mail: [spam@krebsco.de](mailto:spam@krebsco.de)
- Github: https://github.com/krebs/krops/
