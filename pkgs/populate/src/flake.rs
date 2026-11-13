//! Flake and flake-input sources, and drawing inputs from sources.
//!
//! This builds the same shell code as shell.nix generates, with every value
//! quoted, so both implementations behave alike while the code moves to
//! Rust piece by piece.

use crate::run::{quote as q, Context};
use crate::sh;
use crate::spec::{Follows, Source};
use serde_json::{Map, Value};
use std::collections::{BTreeMap, BTreeSet};

pub const LOCK_HAS_INPUT: &str = include_str!("flake/lock-has-input.nix");
pub const METADATA_SUBDIR: &str = include_str!("flake/metadata-subdir.nix");
const SUBDIRS: &str = include_str!("flake/subdirs.jq");
const SELECTED: &str = include_str!("flake/selected.jq");
const SELF_IS_REMOTE: &str = include_str!("flake/self-is-remote.jq");
const SELF_LOCKED: &str = include_str!("flake/self-locked.jq");

fn bool_setting(settings: &Map<String, Value>, key: &str, default: bool) -> bool {
    settings
        .get(key)
        .and_then(Value::as_bool)
        .unwrap_or(default)
}

fn str_setting<'a>(settings: &'a Map<String, Value>, key: &str) -> Option<&'a str> {
    settings.get(key).and_then(Value::as_str)
}

fn patches(settings: &Map<String, Value>) -> Vec<&str> {
    settings
        .get("patches")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .collect()
}

/// Whether a source's inputs get drawn from other sources by a generated
/// flake in .populate/flakes, instead of by rewriting the lock file of the
/// flake in the source.  Symlink sources point at other sources, whose lock
/// files stay as they are.
pub fn has_generated_flake(source: &Source) -> bool {
    !source.follows().is_empty()
        && (source.kind == "symlink" || !bool_setting(&source.settings, "rewriteLock", true))
}

/// Whether a flake or flake-input source gets delivered as a copy, which
/// gets patched, gets its lock file rewritten, or is materialized.
pub fn derives_flake(source: &Source) -> bool {
    let settings = &source.settings;
    matches!(source.kind.as_str(), "flake" | "flake-input")
        && (bool_setting(settings, "materialize", false)
            || !patches(settings).is_empty()
            || (bool_setting(settings, "rewriteLock", true) && !source.follows().is_empty()))
}

/// Shell code running body on the target: as it is for the local target,
/// and over ssh, via sudo if the target says so, for remote ones.  The
/// definitions in sh::prelude come first.
pub fn run_shell(context: &Context, body: &str) -> String {
    let command = format!("{}\n{body}", sh::prelude());
    if context.local {
        format!("(\n{command}\n)")
    } else if context.target.sudo {
        format!(
            "{} {} {}",
            q(&context.ssh.to_string_lossy()),
            q(&context.target.host),
            q(&format!("sudo sh -c {}", q(&command)))
        )
    } else {
        format!(
            "{} {} {}",
            q(&context.ssh.to_string_lossy()),
            q(&context.target.host),
            q(&command)
        )
    }
}

/// Shell code transferring source, a shell word, to path on the target, as
/// rsync::transfer does without .rsync-filter files.
fn rsync_text(context: &Context, path: &str, source: &str, checksum: bool) -> String {
    format!(
        r#"{prepare}
source_path={source}
if test -d "$source_path"; then
  source_path=$source_path/
fi
rsync {checksum} {rsync_path} -e {ssh} --protect-args \
    --itemize-changes \
    --out-format={format} \
    --info=backup,del,copy,misc,mount,name,nonreg,remove,skip,symsafe \
    --omit-dir-times \
    --omit-link-times \
    -rlptD \
    --delete-excluded \
    "$source_path" {destination} >&2
"#,
        prepare = run_shell(
            context,
            &format!(
                "set -- {} {}\n{}",
                q(path),
                q(&context.name(path)),
                sh::break_hard_links()
            )
        ),
        checksum = if checksum { "--checksum" } else { "" },
        rsync_path = if context.target.sudo {
            "--rsync-path='sudo rsync'"
        } else {
            ""
        },
        ssh = q(&context.ssh.to_string_lossy()),
        format = q("%i %n%L %''b/%''l"),
        destination = q(&context.rsync_destination(path)),
    )
}

fn use_state(sentinel: &str, names: &[&str]) -> String {
    let mut call = format!("use_state {}", q(sentinel));
    for name in names {
        call.push(' ');
        call.push_str(&q(name));
    }
    call
}

/// Delivers a flake or flake-input source named name to path.  Returns the
/// shell code doing it on the deploying machine, in the source's working
/// directory.
pub fn flake_input(context: &Context, name: &str, path: &str, source: &Source) -> String {
    let settings = &source.settings;
    let url = str_setting(settings, "url").unwrap_or_default();
    let input = if source.kind == "flake" {
        None
    } else {
        str_setting(settings, "name")
    };
    let input_path: Vec<&str> = input.map(|i| i.split('/').collect()).unwrap_or_default();
    let fetch_on_target = bool_setting(settings, "fetchOnTarget", false);
    let dir = path.rsplit_once('/').map(|(d, _)| d).unwrap_or("");
    let sentinel = format!("{dir}/.populate");
    let derived = derives_flake(&Source {
        kind: "flake".into(),
        settings: settings.clone(),
    });
    let link_path = if derived {
        format!("{sentinel}/derived/{name}/original")
    } else {
        path.to_string()
    };
    let patches = patches(settings);

    // Uploads the patches to .populate/patches/<name>, numbered in order.
    let upload_patches = if patches.is_empty() {
        String::new()
    } else {
        let mut text = String::from("rm -fR \"$PWD\"/patches\nmkdir \"$PWD\"/patches\n");
        for (i, patch) in patches.iter().enumerate() {
            let base = patch.rsplit('/').next().unwrap_or(patch);
            text += &format!(
                "cp {} \"$PWD\"/patches/{}\n",
                q(patch),
                q(&format!("{:04}-{base}", i + 1))
            );
        }
        text += &run_shell(
            context,
            &format!(
                "set -efu\n{}\nmkdir -p {}\n",
                use_state(&sentinel, &[name]),
                q(&format!("{sentinel}/patches"))
            ),
        );
        text.push('\n');
        text += &rsync_text(
            context,
            &format!("{sentinel}/patches/{name}"),
            "\"$PWD\"/patches",
            true,
        );
        text
    };

    let is_remote_ref = {
        let scheme: String = url
            .chars()
            .take_while(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || *c == '+')
            .collect();
        !scheme.is_empty()
            && url[scheme.len()..].starts_with(':')
            && ![
                "file",
                "flake",
                "git+file",
                "hg+file",
                "path",
                "tarball+file",
            ]
            .contains(&scheme.as_str())
    };

    let no_input = format!(
        ">&2 printf 'error: flake %s has no input %s\\n' {} {}\nexit 1\n",
        q(url),
        q(input.unwrap_or(""))
    );

    let overridden: Vec<Vec<String>> = Source {
        kind: "flake".into(),
        settings: settings.clone(),
    }
    .follows()
    .into_iter()
    .map(|f| f.path)
    .collect();
    let require_inputs = bool_setting(settings, "requireInputs", true);

    // Shell function printing the store path $1, followed by the inputs its
    // flake in the subdirectory $2 pins in its own lock file.  Without a
    // lock file, locking would change the flake, so there are no such
    // inputs.  Inputs that get drawn from other sources are left out, with
    // all they pin: Nix archives an empty flake in their place, so it
    // doesn't fetch them.
    let closure = |nix: &str, mktemp: &str| -> String {
        let overridden_json = serde_json::to_string(&overridden).expect("serializes");
        let mut overrides = String::new();
        if !overridden.is_empty() {
            overrides += &format!(
                "closure_empty=$({mktemp} -d)\necho '{{ outputs = _: {{}}; }}' > \"$closure_empty\"/flake.nix\n"
            );
            for path in &overridden {
                overrides += &format!(
                    "set -- \"$@\" --override-input {} \"path:$closure_empty\"\n",
                    q(&path.join("/"))
                );
            }
        }
        let on_failure = if require_inputs {
            format!(
                ">&2 printf 'error: source %s: the inputs its own lock file pins can'\"'\"'t be delivered%s\\n' \\\n    {} {}\nexit 1\n",
                q(name),
                q(if input.is_some() {
                    ".  Set its requireInputs to false to deliver it anyway."
                } else {
                    ""
                })
            )
        } else {
            format!(
                r#"# Without --no-update-lock-file, Nix adds what the lock file
# lacks.
if closure_archive=$(
  {nix} flake archive --json --no-write-lock-file "$@" "$closure_flake"
); then
  >&2 printf 'warning: source %s: its own lock file needs to be updated; delivering it with the inputs Nix locks now, which evaluating it may not use\n' \
      {name}
  closure_paths "$closure_archive"
else
  >&2 printf 'warning: source %s: the inputs its own lock file pins can'"'"'t be delivered; delivering it without them\n' \
      {name}
fi
"#,
                name = q(name)
            )
        };
        format!(
            r#"
# Prints the store paths in nix flake archive's output $1.
closure_paths() {{
  ARCHIVE=$1 OVERRIDDEN={overridden_json} \
  {nix} eval --impure --raw --expr '
    let
      overridden = builtins.fromJSON (builtins.getEnv "OVERRIDDEN");
      # Inputs given by relative paths are part of their parent.
      paths = prefix: node: builtins.concatMap
        (name: let
          input = node.inputs.${{name}};
          path = prefix ++ [ name ];
        in
          if builtins.elem path overridden then []
          else
            (if input ? path then [ input.path ] else []) ++
            paths path input)
        (builtins.attrNames (node.inputs or {{}}));
    in
      builtins.concatStringsSep "\n"
        (paths [] (builtins.fromJSON (builtins.getEnv "ARCHIVE")))
  '
  echo
}}
closure() {{
  printf '%s\n' "$1"
  closure_dir=$1${{2:+/$2}}
  if test -e "$closure_dir"/flake.nix && test -e "$closure_dir"/flake.lock; then
    closure_flake=path:$1${{2:+?dir=$2}}
    set --
    {overrides}
    if closure_archive=$(
      {nix} flake archive --json --no-update-lock-file "$@" "$closure_flake"
    ); then
      closure_paths "$closure_archive"
    else
      {on_failure}
    fi
    {cleanup}
  fi
}}
"#,
            overridden_json = q(&overridden_json),
            cleanup = if overridden.is_empty() {
                ""
            } else {
                "rm -R \"$closure_empty\""
            },
        )
    };

    let inputs_roots = format!("{sentinel}/flake-inputs/{name}");
    let inputs_roots_parent = format!("{sentinel}/flake-inputs");
    let uploads = format!("{sentinel}/flake-uploads");
    let upload = format!("{uploads}/{name}");
    let remove_upload = format!(
        r#"remove_tree {upload}
# Sources get populated one after another, so no other source uses the
# directory meanwhile.
if test -d {uploads} && test -z "$(ls -A {uploads})"; then
  rmdir {uploads}
fi
"#,
        upload = q(&upload),
        uploads = q(&uploads)
    );

    // Reads the subdirectory containing the flake or input, which may be
    // empty, followed by store paths from stdin.  Links the first store
    // path, or the subdirectory therein, at the link path, and registers it
    // and the remaining ones as garbage collector roots.  Roots get added
    // before obsolete ones get removed, so the inputs stay rooted.
    let link = format!(
        r#"set -efu
read -r dir
read -r path
{use_state}
{mkdir_derived}
make_room_for_link {link_path} {link_name}
nix-store --realise "$path" --add-root {link_path} --indirect >/dev/null
# The garbage collector follows the link into the store path.
if test -n "$dir"; then
  ln -fns "$path/$dir" {link_path}
fi

# Left behind by an interrupted run, or not needed anymore.
{remove_upload}
mkdir -p {roots}
roots=
while read -r path; do
  if test -z "$path"; then
    continue
  fi
  root=$(basename "$path")
  if test "$(readlink {roots}/"$root")" != "$path"; then
    nix-store --realise "$path" \
        --add-root {roots}/"$root" --indirect \
      >/dev/null
  fi
  roots="$roots $root"
done
ls -A {roots} | while read -r root; do
  case " $roots " in
    *" $root "*) ;;
    *) rm {roots}/"$root" ;;
  esac
done
# An input without own inputs leaves the directory empty.
if test -z "$roots"; then
  rmdir {roots}
  if test -z "$(ls -A {roots_parent})"; then
    rmdir {roots_parent}
  fi
fi
"#,
        use_state = use_state(&sentinel, &[name]),
        mkdir_derived = if derived {
            format!(
                "mkdir -p {}",
                q(link_path.rsplit_once('/').map(|(d, _)| d).unwrap_or(""))
            )
        } else {
            String::new()
        },
        link_path = q(&link_path),
        link_name = q(&context.name(&link_path)),
        roots = q(&inputs_roots),
        roots_parent = q(&inputs_roots_parent),
    );

    // Reads the selection, as selected produces it, and the store path of
    // the flake itself from stdin, fetches what's selected, unless it's the
    // flake itself, which gets added from the upload directory unless the
    // store has it already, then fetches the inputs its own lock file
    // pins, and links the results.
    let fetch_and_link = format!(
        r#"set -efu
require_flakes 'fetching flake inputs on the target'
read -r selected
read -r self
read -r expected
if test -n "$self" && ! nix-store --check-validity "$self" 2>/dev/null; then
  name=$(basename "$self" | cut -c34-)
  mv {upload}/tree {upload}/"$name"
  added=$(nix-store --add-fixed --recursive sha256 {upload}/"$name")
  {remove_upload}
  if test "$added" != "$self"; then
    >&2 printf 'error: flake %s arrived as %s instead of %s\n' \
        {url} "$added" "$self"
    exit 1
  fi
fi
# Fetching contacts where the input comes from even if the store has what
# the lock file pins.
if test -n "$expected" && ! nix-store --check-validity "$expected" 2>/dev/null; then
  expected=
fi
# The store path and the subdirectory, on separate lines.  Inputs referring
# to local paths can only be fetched if the target has them as well.
fetched=$(
  FLAKE={url} INPUT={input} \
  SELECTED=$selected SELF=$self EXPECTED=$expected \
  nix eval --impure --raw --expr '
    let
      selected = builtins.fromJSON (builtins.getEnv "SELECTED");
      expected = builtins.getEnv "EXPECTED";
      selectedPath =
        if selected.self || expected != "" then null
        else localPath selected.locked;
      path =
        if selected.self then builtins.getEnv "SELF"
        else if expected != "" then expected
        else (builtins.fetchTree selected.locked).outPath;
      dir = path + (if selected.subdir == "" then "" else "/" + selected.subdir);
      lock =
        if builtins.pathExists (dir + "/flake.lock")
          then builtins.fromJSON (builtins.readFile (dir + "/flake.lock"))
          else {{ nodes = {{}}; }};
      localPath = locked:
        if (locked.type or null) == "path" then locked.path
        else let
          match = builtins.match "file:(//)?(.*)" (locked.url or "");
        in
          if match == null then null else builtins.elemAt match 1;
      missing = builtins.filter
        (key: let
          p = localPath (lock.nodes.${{key}}.locked or {{}});
        in
          p != null && builtins.substring 0 1 p == "/" && !builtins.pathExists p)
        (builtins.attrNames lock.nodes);
      key = builtins.head missing;
    in
      if selectedPath != null && builtins.substring 0 1 selectedPath == "/" && !builtins.pathExists selectedPath then
        throw "flake ${{builtins.getEnv "FLAKE"}}: input ${{builtins.getEnv "INPUT"}} refers to ${{selectedPath}}, which does not exist on the target"
      else if missing != [] then
        throw "flake ${{builtins.getEnv "FLAKE"}}: input ${{key}} refers to ${{localPath lock.nodes.${{key}}.locked}}, which does not exist on the target"
      else
        path + "\n" + selected.subdir
  '
)
path=$(printf '%s\n' "$fetched" | sed -n 1p)
subdir=$(printf '%s\n' "$fetched" | sed -n 2p)
{closure}
# Not in the pipeline, where failing wouldn't fail populate.
paths=$(closure "$path" "$subdir")
printf '%s\n%s\n' "$subdir" "$paths" | {{
  {link}
}}
"#,
        upload = q(&upload),
        url = q(url),
        input = q(input.unwrap_or("")),
        closure = closure("nix", "mktemp"),
    );

    // Fetches the flake and its inputs, and links the results.
    let archive_and_link = format!(
        r#"set -efu
require_flakes 'fetching flakes on the target'
metadata=$(nix flake metadata --json --no-update-lock-file {url})
# The store path and the subdirectory, on separate lines.
fetched=$(
  METADATA=$metadata nix eval --impure --raw --expr {expr}
)
path=$(printf '%s\n' "$fetched" | sed -n 1p)
subdir=$(printf '%s\n' "$fetched" | sed -n 2p)
{closure}
paths=$(closure "$path" "$subdir")
printf '%s\n%s\n' "$subdir" "$paths" | {{
  {link}
}}
"#,
        url = q(url),
        expr = q(&format!(
            "let\n  metadata = builtins.fromJSON (builtins.getEnv \"METADATA\");\nin\n  metadata.path + \"\\n\" + ({METADATA_SUBDIR}) metadata\n"
        )),
        closure = closure("nix", "mktemp"),
    );

    let nix_ = "nix --extra-experimental-features 'nix-command flakes'";
    let selected_jq = format!("{SUBDIRS}{SELECTED}");
    let self_locked_jq = format!("{SUBDIRS}{SELF_LOCKED}");

    if fetch_on_target && input.is_none() && is_remote_ref {
        return format!(
            "{upload_patches}\n{}\n",
            run_shell(context, &archive_and_link)
        );
    }

    let self_text = if fetch_on_target {
        let upload_self = if context.local {
            String::new()
        } else {
            format!(
                r#"if ! printf '%s\n' "$self" | {{
  {check}
}}; then
  {prepare}
  # Without applying .rsync-filter files, which would change the flake.
  {rsync}
fi
"#,
                check = run_shell(
                    context,
                    "read -r self\nnix-store --check-validity \"$self\" 2>/dev/null\n"
                ),
                prepare = run_shell(
                    context,
                    &format!(
                        "set -efu\n{}\n{remove_upload}\nmkdir -p {}\n",
                        use_state(&sentinel, &[name]),
                        q(&upload)
                    )
                ),
                rsync = rsync_text(context, &format!("{upload}/tree"), "\"$self\"", false),
            )
        };
        format!(
            r#"# The flake itself has no lock entry, so the target fetches it by its
# locked reference, if it can, or else receives it.
if jq -e {self_is_remote} "$cache" >/dev/null; then
  selected=$(
    jq -c --argjson selected "$selected" {self_locked} \
      "$cache"
  )
else
  self=$(jq -r .path "$cache")
  {upload_self}
fi
"#,
            self_is_remote = q(SELF_IS_REMOTE),
            self_locked = q(&self_locked_jq),
        )
    } else {
        "self=$(jq -r .path \"$cache\")\n".to_string()
    };

    let deliver = if fetch_on_target {
        format!(
            "printf '%s\\n%s\\n%s\\n' \"$selected\" \"$self\" \"$expected\" | {{\n  {}\n}}\n",
            run_shell(context, &fetch_and_link)
        )
    } else {
        let copy = if context.local {
            String::new()
        } else {
            format!(
                "mkdir -p \"$PWD\"/bin\nln -fns {} \"$PWD\"/bin/ssh\nPATH=$PWD/bin:$PATH \\\n{nix_} copy --to {} $paths >&2\n",
                q(&context.ssh_nix.to_string_lossy()),
                q(&format!("ssh://{}", context.target.host))
            )
        };
        format!(
            r#"path=$self
if test -z "$path"; then
  if test -n "$expected" &&
      nix-store --check-validity "$expected" 2>/dev/null; then
    path=$expected
  else
    path=$(
      SELECTED=$selected {nix_} eval --impure --raw --expr '
        (builtins.fetchTree
          (builtins.fromJSON (builtins.getEnv "SELECTED")).locked).outPath
      '
    )
  fi
fi
subdir=$(printf '%s\n' "$selected" | jq -r .subdir)
{closure}
paths=$(closure "$path" "$subdir")

{copy}
printf '%s\n%s\n' "$subdir" "$paths" | {{
  {link}
}}
"#,
            closure = closure(nix_, "mktemp"),
            link = run_shell(context, &link),
        )
    };

    format!(
        r#"set -efu
{upload_patches}

cache=$TMPDIR/flake-metadata.$(
  printf %s {url} |
  sha256sum |
  cut -c-32
).json
if ! test -e "$cache"; then
  {{
    {nix_} flake metadata --json --no-update-lock-file {url}
  }} > "$cache"
fi

if ! selected=$(
  jq -ce --argjson input {input_path} {selected} \
    "$cache" 2>/dev/null
); then
  {no_input}
fi

self=
if printf '%s\n' "$selected" | jq -e .self >/dev/null; then
  {self_text}
fi

# The store path the lock file pins what's selected to, which is the one of
# a directory named source with the locked hash.  A store that has it needs
# no fetching, which contacts where the input comes from even then.
expected=
hash=$(printf '%s\n' "$selected" | jq -r '.locked.narHash // empty')
case $hash in
  sha256-*)
    expected=$(
      nix-store --print-fixed-path --recursive sha256 "$(
        printf %s "${{hash#sha256-}}" |
        base64 -d |
        od -An -v -tx1 |
        tr -d ' \n'
      )" source
    )
    ;;
esac

{deliver}
"#,
        url = q(url),
        input_path = q(&serde_json::to_string(&input_path).expect("serializes")),
        selected = q(&selected_jq),
    )
}

/// Draws inputs of flakes in sources from other sources, and derives what
/// the target paths of flake and flake-input sources that get patched, get
/// their lock files rewritten, or are materialized get.  Sources get
/// processed in the order they draw inputs from each other.  Returns the
/// shell code to run on the target, which also removes state that sources
/// don't need anymore.
///
/// Inputs get drawn by rewriting the lock file of the flake in the source
/// with nix flake lock --override-input: in place for file and git sources,
/// and in a copy for flake and flake-input sources.  Sources with
/// rewriteLock set to false, and symlink sources, get a generated flake in
/// .populate/flakes/<name> instead, which re-exports the outputs of the
/// flake in the source, with those inputs drawn from the other sources.
/// Lock files get rewritten or generated on every run, so they match the
/// sources.
pub fn flakes(context: &Context, dir: &str, sources: &BTreeMap<String, Source>) -> String {
    let sentinel = format!("{dir}/.populate");
    let flakes_dir = format!("{sentinel}/flakes");
    let derived_dir = format!("{sentinel}/derived");
    let patches_dir = format!("{sentinel}/patches");
    let follows: BTreeMap<&str, Vec<Follows>> = sources
        .iter()
        .map(|(n, s)| (n.as_str(), s.follows()))
        .collect();
    let drawing: BTreeSet<&str> = follows
        .iter()
        .filter(|(_, f)| !f.is_empty())
        .map(|(n, _)| *n)
        .collect();
    let generated: BTreeSet<&str> = sources
        .iter()
        .filter(|(_, s)| has_generated_flake(s))
        .map(|(n, _)| n.as_str())
        .collect();
    let derived: BTreeSet<&str> = sources
        .iter()
        .filter(|(_, s)| derives_flake(s))
        .map(|(n, _)| n.as_str())
        .collect();
    let patched: BTreeSet<&str> = sources
        .iter()
        .filter(|(_, s)| !patches(&s.settings).is_empty())
        .map(|(n, _)| n.as_str())
        .collect();
    let names: BTreeSet<&str> = drawing.union(&derived).copied().collect();

    // Source names become input names in generated flakes, where Nix
    // accepts fewer names than populate.  Others get replaced by one
    // derived from them.
    let input_name = |name: &str| -> String {
        let ok = name.chars().next().is_some_and(|c| c.is_ascii_alphabetic())
            && name
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
            && name != "self";
        if ok {
            name.to_string()
        } else {
            format!("source-{}", &sha256_hex(name.as_bytes())[..16])
        }
    };
    let drawn_from =
        |name: &str| -> Vec<String> { follows[name].iter().map(|f| f.source.clone()).collect() };
    let sorted = toposort(&names, &drawn_from);

    // Shell word for the URL of the flake that inputs drawn from a source
    // use: its generated flake, if it has one, so overrides don't need to
    // be repeated, or else the flake in the source.  Nix refuses path: URLs
    // with symlinks on the way, which the target directory may be, so paths
    // get resolved.
    let url = |name: &str| -> String {
        if generated.contains(name) {
            format!(
                "\"path:$(url_path \"$(readlink -f {})\")\"",
                q(&format!("{flakes_dir}/{name}"))
            )
        } else {
            format!("\"$(flake_url {})\"", q(name))
        }
    };

    // Where the input at path of the flake in the source named name is in
    // the flake that the source's inputs get drawn into: the flake itself,
    // or its generated flake.  On the way, inputs that get drawn from
    // sources are the flakes of those sources, where drawing went on, so
    // the path continues there.  A generated flake has its source and the
    // sources that one draws from as inputs, and nothing else, so the path
    // names them there.
    fn parent_of<'a>(follows: &'a [Follows], path: &[String]) -> Option<&'a Follows> {
        (1..path.len())
            .rev()
            .find_map(|n| follows.iter().find(|f| f.path == path[..n]))
    }
    fn drawn_path(
        name: &str,
        path: &[String],
        follows: &BTreeMap<&str, Vec<Follows>>,
        generated: &BTreeSet<&str>,
        input_name: &dyn Fn(&str) -> String,
    ) -> Vec<String> {
        let parent = parent_of(&follows[name], path);
        match (generated.contains(name), parent) {
            (true, None) => [vec![input_name(name)], path.to_vec()].concat(),
            (true, Some(p)) => [
                vec![input_name(&p.source)],
                drawn_path(
                    &p.source,
                    &path[p.path.len()..],
                    follows,
                    generated,
                    input_name,
                ),
            ]
            .concat(),
            (false, None) => path.to_vec(),
            (false, Some(p)) => [
                p.path.clone(),
                drawn_path(
                    &p.source,
                    &path[p.path.len()..],
                    follows,
                    generated,
                    input_name,
                ),
            ]
            .concat(),
        }
    }
    let drawn_path =
        |name: &str, path: &[String]| drawn_path(name, path, &follows, &generated, &input_name);

    // The inputs that drawing the input at path of the flake in the source
    // named name needs to exist, as (name, path) of the source whose flake
    // has the input at path.
    fn input_checks(
        name: &str,
        path: &[String],
        follows: &BTreeMap<&str, Vec<Follows>>,
    ) -> Vec<(String, Vec<String>)> {
        match parent_of(&follows[name], path) {
            None => vec![(name.to_string(), path.to_vec())],
            Some(p) => [
                vec![(name.to_string(), p.path.clone())],
                input_checks(&p.source, &path[p.path.len()..], follows),
            ]
            .concat(),
        }
    }

    // Sets the positional parameters to nix flake lock's arguments for
    // drawing the inputs of the flake in source name from other sources.
    let override_args = |name: &str| -> String {
        let mut text = String::from("set --\n");
        for f in &follows[name] {
            text += &format!(
                "set -- \"$@\" --override-input {} {}\n",
                q(&drawn_path(name, &f.path).join("/")),
                url(&f.source)
            );
        }
        text
    };

    // Rewrites the lock file of the flake in a file or git source in place.
    let rewrite = |name: &str| -> String {
        format!(
            "(\n{}own_lock \"$(readlink -f {})\"\nnix flake lock \"$@\" \"$(flake_url {})\" >&2\n)\n",
            override_args(name),
            q(&format!("{dir}/{name}")),
            q(name)
        )
    };

    // Derives what the target path of a flake or flake-input source gets
    // from what got delivered to .populate/derived/<name>/original: a copy,
    // which gets patched and gets its lock file rewritten.  Unless
    // materialized, the copy gets added to the store, and the target path
    // becomes a link to it.  Copies get made again only if what they derive
    // from changes: materialized ones if the delivered store path, the
    // patches, or what inputs get drawn from which sources changes, and
    // others also if the sources they draw inputs from change.
    let derive = |name: &str| -> String {
        let source = &sources[name];
        let settings = &source.settings;
        let materialize = bool_setting(settings, "materialize", false);
        let rewrite_lock = bool_setting(settings, "rewriteLock", true) && drawing.contains(name);
        let target_path = format!("{dir}/{name}");
        let dir_ = format!("{derived_dir}/{name}");
        let has_patches = !patches(settings).is_empty();
        let follows_json: Vec<Value> = follows[name]
            .iter()
            .map(|f| serde_json::json!({ "path": f.path, "source": f.source }))
            .collect();
        // Like Nix' toJSON: attributes sorted by name.
        let spec = serde_json::to_string(&serde_json::json!({
            "follows": follows_json,
            "materialize": materialize,
            "rewriteLock": rewrite_lock,
        }))
        .expect("serializes");
        let patch_dir = format!("{patches_dir}/{name}");
        let apply_patches = if has_patches {
            format!(
                r#"ls {pd} | while read -r patch; do
  if ! patch -p1 -s --batch --no-backup-if-mismatch \
      -i {pd}/"$patch" >&2; then
    >&2 printf 'error: patch %s does not apply to source %s\n' \
        "$(printf %s "$patch" | cut -c6-)" {name}
    exit 1
  fi
done
"#,
                pd = q(&patch_dir),
                name = q(name)
            )
        } else {
            String::new()
        };
        let remove_work = format!("remove_tree {}", q(&format!("{dir_}/work")));
        let key_patches = if has_patches {
            format!(
                "ls {pd} | while read -r patch; do\n  sha256sum {pd}/\"$patch\"\ndone\n",
                pd = q(&patch_dir)
            )
        } else {
            String::new()
        };
        let key_drawn = if rewrite_lock && !materialize {
            let mut text = override_args(name);
            text += "printf '%s\\n' \"$@\"\n# Sources outside the store can change without changing their\n# path.\n";
            let mut seen = BTreeSet::new();
            for source in drawn_from(name) {
                if !seen.insert(source.clone()) {
                    continue;
                }
                let source = source.as_str();
                let p = if generated.contains(source) {
                    format!("{flakes_dir}/{source}")
                } else {
                    format!("{dir}/{source}")
                };
                text += &format!(
                    "drawn=$(readlink -f {})\ncase $drawn in\n  /nix/store/*) ;;\n  *) nix-hash --type sha256 \"$drawn\" ;;\nesac\n",
                    q(&p)
                );
            }
            text
        } else {
            String::new()
        };
        let body = if materialize {
            let relock = if rewrite_lock {
                format!(
                    "{}own_lock {}\nnix flake lock \"$@\" \"$(flake_url {})\" >&2\n",
                    override_args(name),
                    q(&target_path),
                    q(name)
                )
            } else {
                String::new()
            };
            format!(
                r#"if ! test -e {key} ||
    test "$(cat {key})" != "$key" ||
    test -L {tp} ||
    ! test -d {tp}; then
  cp -R "$original" {work}
  chmod -R u+w {work}
  (
    cd {work}
    {apply_patches}
  )
  remove_foreign_link {tp} {tp_name}
  rm -fR {tp}
  mv {work} {tp}
  write_key "$key"
fi
{relock}
"#,
                key = q(&format!("{dir_}/key")),
                tp = q(&target_path),
                tp_name = q(&context.name(&target_path)),
                work = q(&format!("{dir_}/work")),
            )
        } else {
            let relock = if rewrite_lock {
                format!(
                    "{}# Not just the path, which Nix takes for the enclosing Git\n# work tree, if any.\nnix flake lock \"$@\" \"path:$(url_path \"$work\")${{subdir:+?dir=$subdir}}\" >&2\n",
                    override_args(name)
                )
            } else {
                String::new()
            };
            format!(
                r#"if test -e {key} &&
    test "$(cat {key})" = "$key" &&
    result=$(readlink {result}) &&
    nix-store --check-validity "$result" 2>/dev/null; then
  :
else
  # The copy keeps the name of the delivered store path.
  mkdir {work}
  work=$(readlink -f {work})/$(basename "$path" | cut -c34-)
  cp -R "$path" "$work"
  chmod -R u+w "$work"
  (
    cd "$work"/"$subdir"
    {apply_patches}
  )
  {relock}
  result=$(nix-store --add-fixed --recursive sha256 "$work")
  {remove_work}
  nix-store --realise "$result" \
      --add-root {result} --indirect >/dev/null
  write_key "$key"
fi
make_room_for_link {tp} {tp_name}
# .populate/derived/<name>/result roots the store path.
ln -fns "$result${{subdir:+/$subdir}}" {tp}
"#,
                key = q(&format!("{dir_}/key")),
                result = q(&format!("{dir_}/result")),
                work = q(&format!("{dir_}/work")),
                tp = q(&target_path),
                tp_name = q(&context.name(&target_path)),
            )
        };
        format!(
            r#"(
  # Writes the key $1 to a new file, which then replaces the key, so
  # nothing at its place gets written through, e.g. a symlink.
  write_key() {{
    key_file=$(mktemp {key}.XXXXXX)
    printf '%s\n' "$1" > "$key_file"
    mv -f "$key_file" {key}
  }}
  original=$(readlink -f {original})
  path=$(printf '%s\n' "$original" | cut -d/ -f1-4)
  subdir=${{original#"$path"}}
  subdir=${{subdir#/}}
  key=$(
    {{
      printf '%s\n' "$original" {spec}
      {key_patches}
      {key_drawn}
    }} | sha256sum | cut -c-64
  )
  {remove_work}
  {body}
)
"#,
            key = q(&format!("{dir_}/key")),
            original = q(&format!("{dir_}/original")),
            spec = q(&spec),
        )
    };

    // Generates the flake of a source in .populate/flakes/<name>.
    let generate = |name: &str| -> String {
        let mut drawn: Vec<&str> = Vec::new();
        for f in &follows[name] {
            if !drawn.contains(&f.source.as_str()) {
                drawn.push(&f.source);
            }
        }
        let json = |s: &str| serde_json::to_string(s).expect("serializes");
        // Nix ignores overrides below an input that follows another input,
        // so an input of an input drawn from a source gets overridden at
        // that source.
        let override_line = |f: &Follows| -> String {
            format!(
                "inputs.{}.follows = {};",
                drawn_path(name, &f.path)
                    .iter()
                    .map(|n| json(n))
                    .collect::<Vec<_>>()
                    .join(".inputs."),
                json(&input_name(&f.source))
            )
        };
        let mut text = format!("(\nurl=$(flake_url {})\n", q(name));
        for (i, source) in drawn.iter().enumerate() {
            text += &format!("url{}={}\n", i + 1, url(source));
        }
        let fd = q(&format!("{flakes_dir}/{name}"));
        text += &format!("rm -fR {fd}\nmkdir {fd}\ncd {fd}\n{{\n  echo '{{'\n");
        text += &format!(
            "  printf '  inputs.%s.url = \"%s\";\\n' {} \"$url\"\n",
            q(&json(&input_name(name)))
        );
        for (i, source) in drawn.iter().enumerate() {
            text += &format!(
                "  printf '  inputs.%s.url = \"%s\";\\n' {} \"$url{}\"\n",
                q(&json(&input_name(source))),
                i + 1
            );
            if !generated.contains(source) {
                text += &format!(
                    "  if ! test -e \"$(readlink -f {})\"/flake.nix; then\n    printf '  inputs.%s.flake = false;\\n' {}\n  fi\n",
                    q(&format!("{dir}/{source}")),
                    q(&json(&input_name(source)))
                );
            }
        }
        for f in &follows[name] {
            text += &format!("  printf '  %s\\n' {}\n", q(&override_line(f)));
        }
        text += &format!(
            "  printf '  outputs = inputs: inputs.%s;\\n' {}\n  echo '}}'\n}} > flake.nix\n",
            q(&json(&input_name(name)))
        );
        text += "# Not just ., which Nix takes for the enclosing Git work tree, if any.\nnix flake lock \"path:$(url_path \"$(pwd -P)\")\" >&2\n)\n";
        text
    };

    let process = |name: &str| -> String {
        let mut text = String::new();
        if derived.contains(name) {
            text += &derive(name);
        }
        if generated.contains(name) {
            text += &generate(name);
        } else if drawing.contains(name) && !derived.contains(name) {
            text += &rewrite(name);
        }
        text
    };

    // Removes the entries of the state directory that sources named names
    // don't need anymore, and the directory once it's empty.
    let remove_stale = |state_dir: &str, names: &BTreeSet<&str>| -> String {
        let mut call = format!("remove_others {} ''", q(state_dir));
        for name in names {
            call += &format!(" {}", q(name));
        }
        format!(
            "if test -d {d}; then\n  {call}\n  if test -z \"$(ls -A {d})\"; then\n    rmdir {d}\n  fi\nfi\n",
            d = q(state_dir)
        )
    };

    let all_names: Vec<&str> = sources.keys().map(String::as_str).collect();
    let mut text = format!("set -efu\n{}\n", use_state(&sentinel, &all_names));
    if !names.is_empty() {
        if !drawing.is_empty() {
            text += "require_flakes 'drawing flake inputs from sources'\n";
        }
        text += &format!(
            r#"
# Nix rewrites lock files in place, which also changes what else is a hard
# link to the lock file, e.g. in a backup, or what it is a symlink to.  So
# the lock file of the flake in the directory $1 gets replaced by a copy
# first.  The copy goes to a new file, so nothing that's there already gets
# written through.
own_lock() {{
  if test -e "$1"/flake.lock; then
    own_lock_copy=$(mktemp "$1"/.flake.lock.XXXXXX)
    cp -p "$1"/flake.lock "$own_lock_copy"
    mv -f "$own_lock_copy" "$1"/flake.lock
  fi
}}

# Prints the flake URL of the source named $1.
flake_url() {{
  path=$(readlink -f {dir}/"$1")
  if ! test -d "$path"; then
    >&2 printf 'error: source %s is not a directory\n' "$1"
    exit 1
  fi
  if test -e "$path"/.git; then
    if test -e "$path"/.gitmodules; then
      printf 'git+file:%s?submodules=1' "$(url_path "$path")"
    else
      printf 'git+file:%s' "$(url_path "$path")"
    fi
  else
    printf 'path:%s' "$(url_path "$path")"
  fi
}}

# Inputs can only be drawn into flakes, so check all sources before
# changing anything.
missing=
"#,
            dir = q(dir)
        );
        for name in &drawing {
            let p = if derived.contains(name) {
                format!("{derived_dir}/{name}/original")
            } else {
                format!("{dir}/{name}")
            };
            text += &format!(
                "if ! test -e {}/flake.nix; then\n  missing=\"$missing \"{}\nfi\n",
                q(&p),
                q(name)
            );
        }
        let derived_names: Vec<&str> = derived.iter().copied().collect();
        text += &format!(
            r#"if test -n "$missing"; then
  >&2 printf 'error: source %s draws flake inputs from other sources, but contains no flake.nix\n' $missing
  exit 1
fi

# Nix ignores inputs drawn that the flake doesn't have, with a warning, so a
# misspelt input name would draw nothing.  Prints the flake URL of the
# flake in the source named $1 as delivered.
own_flake_url() {{
  case " "{derived_names}" " in
    *" $1 "*)
      printf 'path:%s' "$(url_path "$(readlink -f {derived_dir}/"$1"/original)")"
      ;;
    *)
      flake_url "$1"
      ;;
  esac
}}
# The lock files of the flakes in the sources, as Nix locks them now, with
# an empty flake in place of each input drawn from a source, which may not
# be reachable, as the one the flake's lock file pins.
locks_dir=$(mktemp -d)
echo '{{ outputs = _: {{}}; }}' > "$locks_dir"/flake.nix
"#,
            derived_names = q(&derived_names.join(" ")),
            derived_dir = q(&derived_dir),
        );
        let mut locked: Vec<String> = Vec::new();
        for name in &drawing {
            for f in &follows[*name] {
                for (c, _) in input_checks(name, &f.path, &follows) {
                    if !locked.contains(&c) {
                        locked.push(c);
                    }
                }
            }
        }
        for name in &locked {
            text += "set --\n";
            for f in &follows[name.as_str()] {
                text += &format!(
                    "set -- \"$@\" --override-input {} \"path:$locks_dir\"\n",
                    q(&f.path.join("/"))
                );
            }
            text += &format!(
                r#"if ! nix flake metadata --json --no-write-lock-file "$@" \
    "$(own_flake_url {n})" > "$locks_dir"/{n}.json; then
  >&2 printf 'error: source %s draws inputs from other sources, but its flake can'"'"'t be locked\n' \
      {n}
  exit 1
fi
"#,
                n = q(name)
            );
        }
        text += &format!(
            r#"# Fails, naming the input, unless the flake in the source named $1 has
# an input at the path $2, a JSON list of input names.  $3 is the source
# that the input $4 of the source $5 gets drawn from.
require_input() {{
  if ! test "$(
    METADATA=$(cat "$locks_dir/$1.json") INPUT=$2 nix eval --impure --raw --expr {expr}
  )" = 1; then
    if test "$1" = "$5"; then
      >&2 printf 'error: source %s draws input %s from source %s, but its flake has no input %s\n' \
          "$5" "$4" "$3" "$4"
    else
      >&2 printf 'error: source %s draws input %s from source %s, but the flake of source %s has no input %s\n' \
          "$5" "$4" "$3" "$1" "$(printf %s "$2" | tr -d '[]"' | tr , /)"
    fi
    exit 1
  fi
}}
"#,
            expr = q(&format!(
                "({LOCK_HAS_INPUT})\n  (builtins.fromJSON (builtins.getEnv \"METADATA\")).locks\n  (builtins.fromJSON (builtins.getEnv \"INPUT\"))\n"
            ))
        );
        for name in &drawing {
            for f in &follows[*name] {
                for (c, path) in input_checks(name, &f.path, &follows) {
                    text += &format!(
                        "require_input {} {} \\\n    {} {} {}\n",
                        q(&c),
                        q(&serde_json::to_string(&path).expect("serializes")),
                        q(&f.source),
                        q(&f.path.join("/")),
                        q(name)
                    );
                }
            }
        }
        text += "rm -R \"$locks_dir\"\n\n";
        if !generated.is_empty() {
            text += &format!("mkdir -p {}\n", q(&flakes_dir));
        }
        for name in &sorted {
            text += &process(name);
        }
    }
    text += "# Remove roots of flake inputs of sources that are neither flake nor\n# flake-input sources anymore.\n";
    for (name, source) in sources {
        if !matches!(source.kind.as_str(), "flake" | "flake-input") {
            text += &format!("rm -fR {}\n", q(&format!("{sentinel}/flake-inputs/{name}")));
        }
    }
    let fi = q(&format!("{sentinel}/flake-inputs"));
    text += &format!(
        "if test -d {fi} &&\n    test -z \"$(ls -A {fi})\"; then\n  rmdir {fi}\nfi\n# Remove what sources left behind that don't need it anymore.\n"
    );
    text += &remove_stale(&flakes_dir, &generated);
    text += &remove_stale(&derived_dir, &derived);
    text += &remove_stale(&patches_dir, &patched);
    format!("{}\n{text}", sh::prelude())
}

/// The names sorted so each comes after the ones it draws inputs from, as
/// nixpkgs' toposort sorts them.  Cycles got refused by the checks.
fn toposort<'a>(
    names: &BTreeSet<&'a str>,
    drawn_from: &dyn Fn(&str) -> Vec<String>,
) -> Vec<&'a str> {
    // toposort a before b if a is drawn from by b: depth-first, like
    // nixpkgs' lib.toposort, on the list in attrNames order.
    fn visit<'a>(
        name: &'a str,
        names: &BTreeSet<&'a str>,
        drawn_from: &dyn Fn(&str) -> Vec<String>,
        done: &mut Vec<&'a str>,
    ) {
        if done.contains(&name) {
            return;
        }
        for from in drawn_from(name) {
            if let Some(from) = names.get(from.as_str()) {
                visit(from, names, drawn_from, done);
            }
        }
        if !done.contains(&name) {
            done.push(name);
        }
    }
    let mut done = Vec::new();
    for name in names {
        visit(name, names, drawn_from, &mut done);
    }
    done
}

/// SHA-256 of data, in hex, like Nix' builtins.hashString.
fn sha256_hex(data: &[u8]) -> String {
    const K: [u32; 64] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4,
        0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe,
        0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f,
        0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
        0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc,
        0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
        0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116,
        0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7,
        0xc67178f2,
    ];
    let mut h: [u32; 8] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab,
        0x5be0cd19,
    ];
    let mut message = data.to_vec();
    message.push(0x80);
    while message.len() % 64 != 56 {
        message.push(0);
    }
    message.extend_from_slice(&((data.len() as u64) * 8).to_be_bytes());
    for chunk in message.chunks(64) {
        let mut w = [0u32; 64];
        for i in 0..16 {
            w[i] = u32::from_be_bytes(chunk[4 * i..4 * i + 4].try_into().expect("4 bytes"));
        }
        for i in 16..64 {
            let s0 = w[i - 15].rotate_right(7) ^ w[i - 15].rotate_right(18) ^ (w[i - 15] >> 3);
            let s1 = w[i - 2].rotate_right(17) ^ w[i - 2].rotate_right(19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16]
                .wrapping_add(s0)
                .wrapping_add(w[i - 7])
                .wrapping_add(s1);
        }
        let mut v = h;
        for i in 0..64 {
            let s1 = v[4].rotate_right(6) ^ v[4].rotate_right(11) ^ v[4].rotate_right(25);
            let ch = (v[4] & v[5]) ^ (!v[4] & v[6]);
            let t1 = v[7]
                .wrapping_add(s1)
                .wrapping_add(ch)
                .wrapping_add(K[i])
                .wrapping_add(w[i]);
            let s0 = v[0].rotate_right(2) ^ v[0].rotate_right(13) ^ v[0].rotate_right(22);
            let maj = (v[0] & v[1]) ^ (v[0] & v[2]) ^ (v[1] & v[2]);
            let t2 = s0.wrapping_add(maj);
            v = [
                t1.wrapping_add(t2),
                v[0],
                v[1],
                v[2],
                v[3].wrapping_add(t1),
                v[4],
                v[5],
                v[6],
            ];
        }
        for (x, y) in h.iter_mut().zip(v) {
            *x = x.wrapping_add(y);
        }
    }
    h.iter().map(|x| format!("{x:08x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sha256() {
        assert_eq!(
            sha256_hex(b""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
        assert_eq!(
            sha256_hex(b"abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }
}
