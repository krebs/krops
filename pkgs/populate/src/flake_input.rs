//! Flake and flake-input sources: delivering a flake, or one input of a
//! flake as its lock file pins it, as a link into the store, with garbage
//! collector roots for its own inputs.

use crate::flake::derives_flake;
use crate::rsync::{self, Config};
use crate::run::{self, Context, Failure, Result};
use crate::sh;
use crate::spec::Source;
use serde_json::{Map, Value};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

/// What a flake-input source delivers: the flake itself, or an input
/// relative to it, which the target can't fetch on its own, or what
/// fetchTree takes as locked, and the subdirectory containing the flake.
#[derive(Clone, Debug, PartialEq)]
pub struct Selection {
    pub is_self: bool,
    pub locked: Option<Value>,
    pub subdir: String,
}

impl Selection {
    fn to_json(&self) -> String {
        serde_json::json!({
            "self": self.is_self,
            "locked": self.locked,
            "subdir": self.subdir,
        })
        .to_string()
    }
}

/// The subdirectory a flake reference or lock entry names, as attribute
/// dir or as query parameter dir of its URL, depending on the version of
/// Nix.  fetchTree supports neither.
fn subdir(reference: &Value) -> String {
    if let Some(dir) = reference.get("dir").and_then(Value::as_str) {
        return dir.to_string();
    }
    let url = reference.get("url").and_then(Value::as_str).unwrap_or("");
    query_dir(url)
        .map(|(_, dir, _)| dir.to_string())
        .unwrap_or_default()
}

/// The first query parameter dir in url: where its separator is, its
/// value, and where it ends, including a following &.
fn query_dir(url: &str) -> Option<(usize, &str, usize)> {
    let bytes = url.as_bytes();
    (0..bytes.len()).find_map(|i| {
        if (bytes[i] == b'?' || bytes[i] == b'&') && url[i + 1..].starts_with("dir=") {
            let start = i + 5;
            let len = url[start..].find('&').unwrap_or(url.len() - start);
            let end = start + len;
            let end_with_amp = if url[end..].starts_with('&') {
                end + 1
            } else {
                end
            };
            Some((i, &url[start..end], end_with_amp))
        } else {
            None
        }
    })
}

/// The reference without its subdirectory, for fetchTree.
fn without_subdir(reference: &Value) -> Value {
    let mut reference = reference.clone();
    if let Value::Object(object) = &mut reference {
        object.remove("__final");
        object.remove("dir");
        if let Some(Value::String(url)) = object.get_mut("url") {
            if let Some((i, _, end)) = query_dir(url) {
                let separator = url[i..i + 1].to_string();
                url.replace_range(i..end, &separator);
            }
            if url.ends_with('?') || url.ends_with('&') {
                url.pop();
            }
        }
    }
    reference
}

/// The subdirectory a node's locked or original reference names.
fn subdir_of(node: &Value) -> String {
    ["locked", "original"]
        .iter()
        .filter_map(|key| node.get(key))
        .filter(|reference| !reference.is_null())
        .map(subdir)
        .find(|dir| !dir.is_empty())
        .unwrap_or_default()
}

/// Selects the flake or input in nix flake metadata's output by the path
/// of input names input, following the flake's lock file, follows
/// included.  An empty follows path removes an input.  Errors say what's
/// missing.
pub fn select(metadata: &Value, input: &[&str]) -> std::result::Result<Selection, String> {
    let locks = &metadata["locks"];
    let root = locks["root"].as_str().unwrap_or("root");
    let nodes = &locks["nodes"];
    fn reference<'a>(
        nodes: &'a Value,
        root: &'a str,
        path: &[&str],
        depth: usize,
    ) -> std::result::Result<String, String> {
        if depth > 64 {
            return Err("follows nest too deep".to_string());
        }
        let mut key = root.to_string();
        for name in path {
            let next = &nodes[&key]["inputs"][name];
            key = match next {
                Value::String(next) => next.clone(),
                Value::Array(follows) if !follows.is_empty() => {
                    let follows: Vec<&str> = follows.iter().filter_map(Value::as_str).collect();
                    reference(nodes, root, &follows, depth + 1)?
                }
                _ => return Err(format!("no input {name}")),
            };
        }
        Ok(key)
    }
    fn join(a: &str, b: &str) -> String {
        match (a.is_empty(), b.is_empty()) {
            (true, _) => b.to_string(),
            (_, true) => a.to_string(),
            _ => format!("{a}/{b}"),
        }
    }
    fn resolve(
        metadata: &Value,
        nodes: &Value,
        root: &str,
        key: &str,
        depth: usize,
    ) -> std::result::Result<Selection, String> {
        let node = &nodes[key];
        if depth > 64 {
            return Err("parents nest too deep".to_string());
        }
        if key == root {
            return Ok(Selection {
                is_self: true,
                locked: None,
                subdir: subdir_of(metadata),
            });
        }
        if let Some(parent) = node.get("parent").and_then(Value::as_array) {
            let parent: Vec<&str> = parent.iter().filter_map(Value::as_str).collect();
            let base = resolve(
                metadata,
                nodes,
                root,
                &reference(nodes, root, &parent, 0)?,
                depth + 1,
            )?;
            let path = node["locked"]["path"].as_str().unwrap_or("");
            let path = path.strip_prefix("./").unwrap_or(path);
            let path = path.strip_suffix('/').unwrap_or(path);
            let path = if path == "." { "" } else { path };
            let subdir = join(&join(&base.subdir, path), &subdir_of(node));
            return Ok(Selection { subdir, ..base });
        }
        Ok(Selection {
            is_self: false,
            locked: Some(without_subdir(&node["locked"])),
            subdir: subdir_of(node),
        })
    }
    let key = reference(nodes, root, input, 0)?;
    resolve(metadata, nodes, root, &key, 0)
}

/// Whether the target can fetch the flake itself, i.e. whether its locked
/// reference doesn't refer to the deploying machine.
pub fn self_is_remote(metadata: &Value) -> bool {
    let locked = &metadata["locked"];
    locked["type"].as_str() != Some("path")
        && !locked["url"].as_str().unwrap_or("").starts_with("file:")
}

/// The store paths in nix flake archive's output, but not those of inputs
/// at the paths overridden, nor what's below them.  Inputs given by
/// relative paths are part of their parent.
pub fn archived_paths(archive: &Value, overridden: &[Vec<String>]) -> Vec<String> {
    fn walk(node: &Value, prefix: &[String], overridden: &[Vec<String>], out: &mut Vec<String>) {
        let Some(inputs) = node.get("inputs").and_then(Value::as_object) else {
            return;
        };
        for (name, input) in inputs {
            let mut path = prefix.to_vec();
            path.push(name.clone());
            if overridden.contains(&path) {
                continue;
            }
            if let Some(store_path) = input.get("path").and_then(Value::as_str) {
                out.push(store_path.to_string());
            }
            walk(input, &path, overridden, out);
        }
    }
    let mut out = Vec::new();
    walk(archive, &[], overridden, &mut out);
    out
}

/// The hexadecimal SHA-256 hash in a narHash like sha256-<base64>.
fn nar_hash_hex(hash: &str) -> Option<String> {
    let encoded = hash.strip_prefix("sha256-")?;
    let alphabet = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut bits = 0u32;
    let mut count = 0;
    let mut out = String::new();
    for byte in encoded.bytes().filter(|b| *b != b'=') {
        let value = alphabet.iter().position(|a| *a == byte)? as u32;
        bits = (bits << 6) | value;
        count += 6;
        if count >= 8 {
            count -= 8;
            out += &format!("{:02x}", (bits >> count) & 0xff);
        }
    }
    Some(out)
}

/// A Nix command with flakes enabled.
fn nix(args: &[&str]) -> Command {
    let mut command = Command::new("nix");
    command
        .args(["--extra-experimental-features", "nix-command flakes"])
        .args(args);
    command
}

/// Whether the store on the deploying machine has path.
fn valid_here(path: &str) -> bool {
    Command::new("nix-store")
        .args(["--check-validity", path])
        .stderr(Stdio::null())
        .status()
        .is_ok_and(|status| status.success())
}

/// The shell code of snippet for the target, with the definitions it uses,
/// enabling flakes for what if given.
fn on_target(snippet: &str, flakes: Option<&str>) -> String {
    let require = flakes
        .map(|what| format!("require_flakes {}\n", run::quote(what)))
        .unwrap_or_default();
    format!(
        "{}{}{require}{snippet}",
        sh::prelude(),
        sh::flake::REMOVE_UPLOAD
    )
}

fn setting<'a>(settings: &'a Map<String, Value>, key: &str) -> Option<&'a Value> {
    settings.get(key)
}

fn flag(settings: &Map<String, Value>, key: &str, default: bool) -> bool {
    setting(settings, key)
        .and_then(Value::as_bool)
        .unwrap_or(default)
}

/// Delivers the flake or flake-input source named name to path, preparing
/// what it needs on the deploying machine in workdir.
pub fn deliver(
    context: &Context,
    name: &str,
    path: &str,
    source: &Source,
    workdir: &Path,
) -> Result<()> {
    let settings = &source.settings;
    let url = setting(settings, "url")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let input = if source.kind == "flake" {
        None
    } else {
        setting(settings, "name").and_then(Value::as_str)
    };
    let input_path: Vec<&str> = input.map(|i| i.split('/').collect()).unwrap_or_default();
    let fetch_on_target = flag(settings, "fetchOnTarget", false);
    let dir = path.rsplit_once('/').map(|(d, _)| d).unwrap_or("");
    let sentinel = format!("{dir}/.populate");
    let as_flake = Source {
        kind: "flake".into(),
        settings: settings.clone(),
    };
    // A source that gets patched, gets its lock file rewritten, or is
    // materialized gets linked in .populate/derived/<name> instead of at
    // the target path, and the flakes step derives what the target path
    // gets.
    let derived = derives_flake(&as_flake);
    let link_path = if derived {
        format!("{sentinel}/derived/{name}/original")
    } else {
        path.to_string()
    };
    let overridden: Vec<Vec<String>> = as_flake.follows().into_iter().map(|f| f.path).collect();
    let require_inputs = flag(settings, "requireInputs", true);
    let hint = if input.is_some() {
        ".  Set its requireInputs to false to deliver it anyway."
    } else {
        ""
    };
    let failure = |message: String| Failure::Message(message);

    upload_patches(context, name, &sentinel, settings, workdir)?;

    // The store paths of the flake or input, followed by the inputs its
    // flake in subdir pins in its own lock file, archived where script
    // runs.
    let closure = |store_path: &str, subdir: &str, on: &dyn Fn(&str, &[&str]) -> Result<String>| {
        let overrides: Vec<String> = overridden.iter().map(|p| p.join("/")).collect();
        let mut args = vec![
            store_path,
            subdir,
            if require_inputs { "1" } else { "" },
            name,
            hint,
        ];
        args.extend(overrides.iter().map(String::as_str));
        let archive = on(sh::flake::ARCHIVE, &args)?;
        let mut paths = vec![store_path.to_string()];
        if !archive.trim().is_empty() {
            let archive: Value = serde_json::from_str(&archive).map_err(|e| {
                failure(format!(
                    "error: can't read what nix flake archive prints: {e}"
                ))
            })?;
            paths.extend(archived_paths(&archive, &overridden));
        }
        Ok::<_, Failure>(paths)
    };
    let link = |subdir: &str, paths: &[String]| -> Result<()> {
        let link_name = context.name(&link_path);
        let mut args = vec![
            sentinel.as_str(),
            name,
            &link_path,
            &link_name,
            if derived { "1" } else { "" },
            subdir,
        ];
        args.extend(paths.iter().map(String::as_str));
        context.run(&on_target(sh::flake::LINK, None), &args)
    };
    let on_target_output = |what: &'static str| {
        move |snippet: &str, args: &[&str]| context.output(&on_target(snippet, Some(what)), args)
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

    // The target fetches the flake itself on its own.
    if fetch_on_target && input.is_none() && is_remote_ref {
        let fetching = "fetching flakes on the target";
        let metadata = context.output(
            &on_target(
                "nix flake metadata --json --no-update-lock-file \"$1\"\n",
                Some(fetching),
            ),
            &[url],
        )?;
        let metadata: Value = serde_json::from_str(&metadata)
            .map_err(|e| failure(format!("error: can't read flake metadata of {url}: {e}")))?;
        let store_path = metadata["path"].as_str().unwrap_or_default();
        let subdir = subdir_of(&metadata);
        let paths = closure(store_path, &subdir, &on_target_output(fetching))?;
        return link(&subdir, &paths);
    }

    let metadata = context.flake_metadata(url, || {
        run::output(&mut nix(&[
            "flake",
            "metadata",
            "--json",
            "--no-update-lock-file",
            url,
        ]))
    })?;
    let no_input = || {
        failure(format!(
            "error: flake {url} has no input {}",
            input.unwrap_or("")
        ))
    };
    let mut selected = select(&metadata, &input_path).map_err(|_| no_input())?;

    let mut self_path = String::new();
    if selected.is_self {
        if fetch_on_target && self_is_remote(&metadata) {
            // The flake itself has no lock entry, so the target fetches it
            // by its locked reference.
            selected = Selection {
                is_self: false,
                locked: Some(without_subdir(&metadata["locked"])),
                ..selected
            };
        } else {
            self_path = metadata["path"].as_str().unwrap_or_default().to_string();
            if fetch_on_target && !context.local {
                upload_self(context, name, &sentinel, &self_path)?;
            }
        }
    }

    // The store path the lock file pins what's selected to, which is the
    // one of a directory named source with the locked hash.  A store that
    // has it needs no fetching, which contacts where the input comes from
    // even then.
    let mut expected = String::new();
    let nar_hash = selected
        .locked
        .as_ref()
        .and_then(|locked| locked.get("narHash"))
        .and_then(Value::as_str)
        .and_then(nar_hash_hex);
    if let Some(hex) = nar_hash {
        expected = run::output(Command::new("nix-store").args([
            "--print-fixed-path",
            "--recursive",
            "sha256",
            &hex,
            "source",
        ]))?
        .trim_end()
        .to_string();
    }

    if fetch_on_target {
        let fetching = "fetching flake inputs on the target";
        let fetched = context.output(
            &on_target(sh::flake::FETCH, Some(fetching)),
            &[
                &sentinel,
                name,
                url,
                input.unwrap_or(""),
                &selected.to_json(),
                &self_path,
                &expected,
            ],
        )?;
        let (store_path, subdir) = fetched.split_once('\n').unwrap_or((&fetched, ""));
        let paths = closure(store_path, subdir, &on_target_output(fetching))?;
        return link(subdir, &paths);
    }

    let store_path = if !self_path.is_empty() {
        self_path
    } else if !expected.is_empty() && valid_here(&expected) {
        expected
    } else {
        let locked = selected.locked.clone().unwrap_or(Value::Null).to_string();
        run::output(
            nix(&[
                "eval",
                "--impure",
                "--raw",
                "--expr",
                "(builtins.fetchTree (builtins.fromJSON (builtins.getEnv \"LOCKED\"))).outPath",
            ])
            .env("LOCKED", locked),
        )?
    };
    let here = |snippet: &str, args: &[&str]| {
        let mut command = run::local_shell(snippet, args, workdir);
        command.env("NIX_CONFIG", nix_config());
        run::output(&mut command)
    };
    let paths = closure(&store_path, &selected.subdir, &here)?;
    if !context.local {
        copy(context, workdir, &paths)?;
    }
    link(&selected.subdir, &paths)
}

/// NIX_CONFIG with flakes enabled.
fn nix_config() -> String {
    let config = std::env::var("NIX_CONFIG").unwrap_or_default();
    format!("{config}\nextra-experimental-features = nix-command flakes")
}

/// Copies store paths to the target with nix copy, which runs ssh from
/// PATH, so that's the ssh for Nix's ssh:// store there.
fn copy(context: &Context, workdir: &Path, paths: &[String]) -> Result<()> {
    let bin = workdir.join("bin");
    let link = bin.join("ssh");
    let prepare = || -> std::io::Result<()> {
        fs::create_dir_all(&bin)?;
        if fs::symlink_metadata(&link).is_ok() {
            fs::remove_file(&link)?;
        }
        std::os::unix::fs::symlink(&context.ssh_nix, &link)
    };
    prepare()
        .map_err(|e| Failure::Message(format!("error: can't prepare {}: {e}", bin.display())))?;
    let path = std::env::var_os("PATH").unwrap_or_default();
    let path =
        std::env::join_paths(std::iter::once(bin.clone()).chain(std::env::split_paths(&path)))
            .map_err(|e| Failure::Message(format!("error: can't extend PATH: {e}")))?;
    let mut command = nix(&["copy", "--to", &format!("ssh://{}", context.target.host)]);
    command.args(paths).env("PATH", path).stdout(run::stderr());
    run::status(&mut command)
}

/// Uploads the source's patches to .populate/patches/<name>, numbered in
/// order.
fn upload_patches(
    context: &Context,
    name: &str,
    sentinel: &str,
    settings: &Map<String, Value>,
    workdir: &Path,
) -> Result<()> {
    let patches: Vec<&str> = settings
        .get("patches")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .collect();
    if patches.is_empty() {
        return Ok(());
    }
    let dir = workdir.join("patches");
    let prepare = || -> std::io::Result<()> {
        if dir.exists() {
            fs::remove_dir_all(&dir)?;
        }
        fs::create_dir(&dir)?;
        for (i, patch) in patches.iter().enumerate() {
            let base = Path::new(patch)
                .file_name()
                .unwrap_or_default()
                .to_string_lossy();
            fs::copy(patch, dir.join(format!("{:04}-{base}", i + 1)))?;
        }
        Ok(())
    };
    prepare().map_err(|e| Failure::Message(format!("error: can't copy patches: {e}")))?;
    context.run(&on_target(sh::flake::PREPARE, None), &[sentinel, name, "1"])?;
    let config = Config {
        filter_files: false,
        use_checksum: true,
        ..Config::default()
    };
    rsync::transfer(
        context,
        &config,
        &dir.to_string_lossy(),
        &format!("{sentinel}/patches/{name}"),
    )
}

/// Uploads the flake itself to a target that can't fetch it, unless the
/// target's store has it already.
fn upload_self(context: &Context, name: &str, sentinel: &str, self_path: &str) -> Result<()> {
    if context.run(sh::flake::VALID, &[self_path]).is_ok() {
        return Ok(());
    }
    run::check_signal()?;
    context.run(&on_target(sh::flake::PREPARE, None), &[sentinel, name, ""])?;
    // Without applying .rsync-filter files, which would change the flake.
    let config = Config {
        filter_files: false,
        ..Config::default()
    };
    let upload: PathBuf = Path::new(sentinel)
        .join("flake-uploads")
        .join(name)
        .join("tree");
    rsync::transfer(context, &config, self_path, &upload.to_string_lossy())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    /// A flake with an input dep, which has an input inner following the
    /// flake's input inner, and an input sub, a flake in a subdirectory.
    fn metadata(locked: Value, original: Value) -> Value {
        json!({
            "locked": { "type": "path", "path": "/src/top", "narHash": "sha256-top" },
            "path": "/nix/store/top-source",
            "locks": {
                "root": "root",
                "version": 7,
                "nodes": {
                    "root": { "inputs": { "dep": "dep", "inner": "inner", "sub": "sub" } },
                    "dep": {
                        "inputs": { "inner": [ "inner" ] },
                        "locked": { "type": "tarball", "url": "http://x/dep.tar.gz", "narHash": "sha256-dep" }
                    },
                    "inner": {
                        "locked": { "type": "tarball", "url": "http://x/inner.tar.gz", "narHash": "sha256-inner" }
                    },
                    "sub": { "locked": locked, "original": original }
                }
            }
        })
    }

    fn attribute() -> Value {
        metadata(
            json!({ "type": "tarball", "url": "http://x/mono.tar.gz", "dir": "sub", "narHash": "sha256-mono" }),
            json!({ "type": "tarball", "url": "http://x/mono.tar.gz", "dir": "sub" }),
        )
    }

    fn mono() -> Selection {
        Selection {
            is_self: false,
            locked: Some(
                json!({ "type": "tarball", "url": "http://x/mono.tar.gz", "narHash": "sha256-mono" }),
            ),
            subdir: "sub".into(),
        }
    }

    #[test]
    fn selection() {
        let url = metadata(
            json!({ "type": "tarball", "url": "http://x/mono.tar.gz?dir=sub", "narHash": "sha256-mono" }),
            json!({ "type": "tarball", "url": "http://x/mono.tar.gz?dir=sub" }),
        );
        assert_eq!(select(&attribute(), &["sub"]), Ok(mono()));
        assert_eq!(select(&url, &["sub"]), Ok(mono()));
        assert_eq!(
            select(&attribute(), &[]),
            Ok(Selection {
                is_self: true,
                locked: None,
                subdir: String::new()
            })
        );
        assert_eq!(
            select(&attribute(), &["dep", "inner"]).map(|s| s.locked),
            Ok(Some(
                json!({ "type": "tarball", "url": "http://x/inner.tar.gz", "narHash": "sha256-inner" })
            ))
        );
        assert_eq!(select(&attribute(), &["nope"]), Err("no input nope".into()));
    }

    #[test]
    fn removed_and_cyclic_follows() {
        let mut removed = attribute();
        removed["locks"]["nodes"]["dep"]["inputs"]["inner"] = json!([]);
        assert_eq!(
            select(&removed, &["dep", "inner"]),
            Err("no input inner".into())
        );
        let mut cyclic = attribute();
        cyclic["locks"]["nodes"]["dep"]["inputs"]["inner"] = json!(["inner", "x"]);
        cyclic["locks"]["nodes"]["inner"]["inputs"] = json!({ "x": ["dep", "inner"] });
        assert_eq!(
            select(&cyclic, &["dep", "inner"]),
            Err("follows nest too deep".into())
        );
    }

    #[test]
    fn relative_path() {
        let mut relative = attribute();
        relative["locked"]["dir"] = json!("sub");
        relative["locks"]["nodes"]["root"]["inputs"]["lib"] = json!("lib");
        relative["locks"]["nodes"]["lib"] =
            json!({ "locked": { "type": "path", "path": "./lib" }, "parent": [] });
        assert_eq!(
            select(&relative, &["lib"]),
            Ok(Selection {
                is_self: true,
                locked: None,
                subdir: "sub/lib".into()
            })
        );
    }

    #[test]
    fn remote() {
        let remote = |locked: Value| self_is_remote(&json!({ "locked": locked }));
        assert!(!remote(json!({ "type": "path", "path": "/src" })));
        assert!(!remote(json!({ "type": "git", "url": "file:///src" })));
        assert!(remote(json!({ "type": "git", "url": "https://x/y" })));
        assert!(remote(
            json!({ "type": "github", "owner": "o", "repo": "r" })
        ));
    }

    #[test]
    fn locked_self() {
        let locked = json!({ "__final": true, "type": "tarball", "url": "http://x/mono.tar.gz?dir=sub", "narHash": "sha256-mono" });
        assert_eq!(Some(without_subdir(&locked)), mono().locked);
        let url = json!({ "url": "http://x/y?rev=1&dir=sub&z=2" });
        assert_eq!(
            without_subdir(&url),
            json!({ "url": "http://x/y?rev=1&z=2" })
        );
    }

    #[test]
    fn subdirs() {
        let of = |m: Value| subdir_of(&m);
        assert_eq!(
            of(json!({
                "locked": { "type": "tarball", "url": "http://x/mono.tar.gz?dir=sub&narHash=sha256-mono" },
                "original": { "type": "tarball", "url": "http://x/mono.tar.gz?dir=sub" }
            })),
            "sub"
        );
        assert_eq!(
            of(json!({
                "locked": { "type": "tarball", "url": "http://x/mono.tar.gz" },
                "original": { "type": "tarball", "url": "http://x/mono.tar.gz?rev=1&dir=sub" }
            })),
            "sub"
        );
        assert_eq!(
            of(json!({ "locked": { "type": "path", "path": "/src/top" } })),
            ""
        );
    }

    #[test]
    fn archive() {
        let archive = json!({
            "path": "/nix/store/top",
            "inputs": {
                "a": { "path": "/nix/store/a", "inputs": { "b": { "path": "/nix/store/b" } } },
                "c": { "path": "/nix/store/c", "inputs": { "d": { "path": "/nix/store/d" } } },
                "rel": { "inputs": {} }
            }
        });
        assert_eq!(
            archived_paths(&archive, &[vec!["c".into()]]),
            vec!["/nix/store/a", "/nix/store/b"]
        );
    }

    #[test]
    fn nar_hashes() {
        assert_eq!(
            nar_hash_hex("sha256-47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=").as_deref(),
            Some("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        );
    }
}
