# Populate, which delivers sources to a target directory.  Given populate's
# arguments, it returns the command delivering them.  implementation selects
# how: "shell" generates a script from the arguments, "rust" runs the
# program in this directory with the arguments as JSON.  rustProgram is that
# program, e.g. one built with cargo during development.
{ coreutils, dash, findutils, git, jq, nix, openssh, pass, passage, rsync
, writers
, implementation ? "shell"
, rustPlatform ? null
, rustProgram ? import ./program.nix { inherit rustPlatform; }
}:

if implementation == "shell" then
  import ./shell.nix {
    inherit coreutils dash findutils git jq nix openssh pass passage rsync
      writers;
  }
else if implementation == "rust" then
  import ./rust.nix {
    inherit coreutils findutils git nix openssh pass passage rsync writers;
    program = rustProgram;
  }
else
  throw "populate: unknown implementation ${builtins.toJSON implementation}"
