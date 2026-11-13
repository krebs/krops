//! Drawing inputs of flakes in sources from other sources, and deriving
//! what flake and flake-input sources that get patched, get their lock
//! files rewritten, or are materialized deliver.
//!
//! Populate decides what to do.  The target runs the fixed snippets of
//! sh::draw, which send back what populate needs to know: where paths
//! resolve to, the lock files of flakes, and what tells whether a derived
//! copy needs to be made again.

use crate::run::{Context, Failure, Result};
use crate::sh;
use crate::spec::{Follows, Source};
use serde_json::{Map, Value};
use std::collections::{BTreeMap, BTreeSet};

/// What needs flakes, for the error if Nix on the target lacks them.
const DRAWING: &str = "drawing flake inputs from sources";

fn bool_setting(settings: &Map<String, Value>, key: &str, default: bool) -> bool {
    settings
        .get(key)
        .and_then(Value::as_bool)
        .unwrap_or(default)
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

/// A path on the target, where it resolves to, and what's there.
#[derive(Debug, Default)]
struct Resolved {
    path: String,
    dir: bool,
    git: bool,
    submodules: bool,
    flake: bool,
}

/// What a path is in a URL: with every byte percent-encoded that isn't a
/// letter, a digit, or one of -._~/.  Nix decodes that, and otherwise
/// takes, e.g., ? and # for delimiters, and refuses blanks.
fn url_path(path: &str) -> String {
    path.bytes()
        .map(|b| {
            if b.is_ascii_alphanumeric() || b"-._~/".contains(&b) {
                (b as char).to_string()
            } else {
                format!("%{b:02x}")
            }
        })
        .collect()
}

/// Source names become input names in generated flakes, where Nix accepts
/// fewer names than populate.  Others get replaced by one derived from
/// them.
fn input_name(name: &str) -> String {
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
}

/// The follows of a source that draws the input at path on the way to it,
/// if any: the one with the longest path that path starts with.
fn parent_of<'a>(follows: &'a [Follows], path: &[String]) -> Option<&'a Follows> {
    (1..path.len())
        .rev()
        .find_map(|n| follows.iter().find(|f| f.path == path[..n]))
}

/// Where the input at path of the flake in the source named name is in the
/// flake that the source's inputs get drawn into: the flake itself, or its
/// generated flake.  On the way, inputs that get drawn from sources are the
/// flakes of those sources, where drawing went on, so the path continues
/// there.  A generated flake has its source and the sources that one draws
/// from as inputs, and nothing else, so the path names them there.
fn drawn_path(
    name: &str,
    path: &[String],
    follows: &BTreeMap<&str, Vec<Follows>>,
    generated: &BTreeSet<&str>,
) -> Vec<String> {
    let parent = parent_of(&follows[name], path);
    let rest = |p: &Follows| drawn_path(&p.source, &path[p.path.len()..], follows, generated);
    match (generated.contains(name), parent) {
        (true, None) => [vec![input_name(name)], path.to_vec()].concat(),
        (true, Some(p)) => [vec![input_name(&p.source)], rest(p)].concat(),
        (false, None) => path.to_vec(),
        (false, Some(p)) => [p.path.clone(), rest(p)].concat(),
    }
}

/// The inputs that drawing the input at path of the flake in the source
/// named name needs to exist, as (name, path) of the source whose flake
/// has the input at path.
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

/// Whether the lock file locks, as nix flake metadata prints it, has an
/// input at path, a list of input names, resolving inputs that follow
/// others.
fn lock_has_input(locks: &Value, path: &[String]) -> bool {
    let nodes = &locks["nodes"];
    let Some(root) = locks["root"].as_str() else {
        return false;
    };
    let input = |key: &str, name: &str| -> Option<&Value> {
        Some(&nodes[key]["inputs"][name]).filter(|input| !input.is_null())
    };
    // The node an input refers to, following follows from the root.
    fn node<'a>(
        reference: Option<&'a Value>,
        root: &'a str,
        input: &dyn Fn(&str, &str) -> Option<&'a Value>,
        depth: usize,
    ) -> Option<&'a str> {
        if depth > 64 {
            return None;
        }
        match reference? {
            Value::String(key) => Some(key),
            Value::Array(names) => names.iter().try_fold(root, |key, name| {
                node(input(key, name.as_str()?), root, input, depth + 1)
            }),
            _ => None,
        }
    }
    let mut key = root;
    for name in path {
        match node(input(key, name), root, &input, 0) {
            Some(next) => key = next,
            None => return false,
        }
    }
    true
}

/// The store path a path below the store is in, and the rest of the path.
fn split_store_path(path: &str) -> (&str, &str) {
    let end = path
        .match_indices('/')
        .nth(3)
        .map(|(i, _)| i)
        .unwrap_or(path.len());
    let rest = &path[end..];
    (&path[..end], rest.strip_prefix('/').unwrap_or(rest))
}

/// The sources, and what drawing inputs and deriving copies needs to know
/// about them.
struct Flakes<'a> {
    context: &'a Context,
    dir: &'a str,
    sources: &'a BTreeMap<String, Source>,
    follows: BTreeMap<&'a str, Vec<Follows>>,
    /// The sources drawing inputs from others.
    drawing: BTreeSet<&'a str>,
    /// The sources with a generated flake.
    generated: BTreeSet<&'a str>,
    /// The sources with derived state.
    derived: BTreeSet<&'a str>,
}

impl<'a> Flakes<'a> {
    fn sentinel(&self) -> String {
        format!("{}/.populate", self.dir)
    }

    fn state(&self, kind: &str, name: &str) -> String {
        format!("{}/{kind}/{name}", self.sentinel())
    }

    fn path(&self, name: &str) -> String {
        format!("{}/{name}", self.dir)
    }

    /// The shell code of snippet for the target, with the definitions it
    /// uses, enabling flakes if flakes is set.
    fn on_target(snippet: &str, flakes: bool) -> String {
        let require = if flakes {
            format!("require_flakes {}\n", crate::run::quote(DRAWING))
        } else {
            String::new()
        };
        format!(
            "{}{}{}{require}{snippet}",
            sh::prelude(),
            sh::GIT_PROBLEMS,
            sh::draw::DEFINITIONS
        )
    }

    fn run(&self, snippet: &str, flakes: bool, args: &[&str]) -> Result<()> {
        self.context.run(&Self::on_target(snippet, flakes), args)
    }

    /// What snippet prints, as the fields ending in null bytes.
    fn fields(&self, snippet: &str, flakes: bool, args: &[&str]) -> Result<Vec<String>> {
        let output = self
            .context
            .output(&Self::on_target(snippet, flakes), args)?;
        let mut fields: Vec<String> = output.split('\0').map(str::to_string).collect();
        // What follows the last null byte.
        fields.pop();
        Ok(fields)
    }

    /// Resolves paths on the target.
    fn resolve(&self, paths: &[String], flakes: bool) -> Result<Vec<Resolved>> {
        let args: Vec<&str> = paths.iter().map(String::as_str).collect();
        let fields = self.fields(sh::draw::RESOLVE, flakes, &args)?;
        if fields.len() != 2 * paths.len() {
            return Err(Failure::Message(
                "error: can't resolve paths on the target".to_string(),
            ));
        }
        Ok(fields
            .chunks(2)
            .map(|field| Resolved {
                path: field[1].clone(),
                dir: field[0].contains('d'),
                git: field[0].contains('g'),
                submodules: field[0].contains('s'),
                flake: field[0].contains('f'),
            })
            .collect())
    }

    /// The flake URL of the source named name, at resolved: git+file: if
    /// it has a .git directory populate can use, else path:.
    fn flake_url(name: &str, resolved: &Resolved) -> Result<String> {
        if !resolved.dir {
            return Err(Failure::Message(format!(
                "error: source {name} is not a directory"
            )));
        }
        let path = url_path(&resolved.path);
        Ok(if resolved.git && resolved.submodules {
            format!("git+file:{path}?submodules=1")
        } else if resolved.git {
            format!("git+file:{path}")
        } else {
            format!("path:{path}")
        })
    }

    /// The flake URL of the source named name, as it is now.
    fn own_url(&self, name: &str) -> Result<String> {
        let resolved = self.resolve(&[self.path(name)], false)?;
        Self::flake_url(name, &resolved[0])
    }

    /// The sources that the source named name draws inputs from, each
    /// once.
    fn drawn_from(&self, name: &str) -> Vec<&'a str> {
        let mut drawn: Vec<&'a str> = Vec::new();
        for f in &self.follows[name] {
            let source = self
                .sources
                .get_key_value(&f.source)
                .map(|(k, _)| k.as_str());
            if let Some(source) = source.filter(|s| !drawn.contains(s)) {
                drawn.push(source);
            }
        }
        drawn
    }

    /// Where the flake that inputs drawn from the source named name use
    /// is: its generated flake, if it has one, so overrides don't need to
    /// be repeated, or else the flake in the source.
    fn drawn_flake(&self, name: &str) -> String {
        if self.generated.contains(name) {
            self.state("flakes", name)
        } else {
            self.path(name)
        }
    }

    /// The URLs of the flakes that inputs drawn from the sources use, and
    /// whether they have a flake.nix.  Nix refuses path: URLs with
    /// symlinks on the way, which the target directory may be, so paths
    /// get resolved.
    fn drawn_urls(&self, sources: &[&str]) -> Result<BTreeMap<String, (String, bool)>> {
        let paths: Vec<String> = sources.iter().map(|s| self.drawn_flake(s)).collect();
        let resolved = self.resolve(&paths, false)?;
        let mut urls = BTreeMap::new();
        for (source, resolved) in sources.iter().zip(resolved) {
            let url = if self.generated.contains(source) {
                format!("path:{}", url_path(&resolved.path))
            } else {
                Self::flake_url(source, &resolved)?
            };
            // A generated flake is a flake.
            let flake = resolved.flake || self.generated.contains(source);
            urls.insert(source.to_string(), (url, flake));
        }
        Ok(urls)
    }

    /// nix flake lock's arguments for drawing the inputs of the flake in
    /// the source named name from other sources.
    fn override_args(&self, name: &str) -> Result<Vec<String>> {
        let urls = self.drawn_urls(&self.drawn_from(name))?;
        let mut args = Vec::new();
        for f in &self.follows[name] {
            args.push("--override-input".to_string());
            args.push(drawn_path(name, &f.path, &self.follows, &self.generated).join("/"));
            args.push(urls[&f.source].0.clone());
        }
        Ok(args)
    }

    /// Fails unless each source drawing inputs contains a flake that has
    /// the inputs drawn, before anything changes.  Nix ignores inputs drawn
    /// that a flake doesn't have, with a warning, so a misspelt input name
    /// would draw nothing.
    fn check(&self) -> Result<()> {
        // The flake in a source as delivered.
        let delivered = |name: &str| {
            if self.derived.contains(name) {
                format!("{}/original", self.state("derived", name))
            } else {
                self.path(name)
            }
        };
        let drawing: Vec<&str> = self.drawing.iter().copied().collect();
        let paths: Vec<String> = drawing.iter().map(|n| delivered(n)).collect();
        let resolved = self.resolve(&paths, true)?;
        let missing: Vec<String> = drawing
            .iter()
            .zip(&resolved)
            .filter(|(_, resolved)| !resolved.flake)
            .map(|(name, _)| {
                format!("error: source {name} draws flake inputs from other sources, but contains no flake.nix")
            })
            .collect();
        if !missing.is_empty() {
            return Err(Failure::Message(missing.join("\n")));
        }

        // The lock files of the flakes in the sources, as Nix locks them
        // now, with an empty flake in place of each input drawn from a
        // source, which may not be reachable, as the one the flake's lock
        // file pins.
        let mut locked: Vec<String> = Vec::new();
        for name in &drawing {
            for f in &self.follows[name] {
                for (c, _) in input_checks(name, &f.path, &self.follows) {
                    if !locked.contains(&c) {
                        locked.push(c);
                    }
                }
            }
        }
        let paths: Vec<String> = locked.iter().map(|n| delivered(n)).collect();
        let resolved = self.resolve(&paths, false)?;
        let mut locks = BTreeMap::new();
        for (name, resolved) in locked.iter().zip(&resolved) {
            let url = if self.derived.contains(name.as_str()) {
                format!("path:{}", url_path(&resolved.path))
            } else {
                Self::flake_url(name, resolved)?
            };
            let overrides: Vec<String> = self.follows[name.as_str()]
                .iter()
                .map(|f| f.path.join("/"))
                .collect();
            let mut args = vec![url.as_str(), name.as_str()];
            args.extend(overrides.iter().map(String::as_str));
            let output = self
                .context
                .output(&Self::on_target(sh::draw::METADATA, true), &args)?;
            let metadata: Value = serde_json::from_str(&output).map_err(|e| {
                Failure::Message(format!("error: can't read flake metadata of {url}: {e}"))
            })?;
            locks.insert(name.clone(), metadata["locks"].clone());
        }

        for name in &drawing {
            for f in &self.follows[name] {
                let input = f.path.join("/");
                for (c, path) in input_checks(name, &f.path, &self.follows) {
                    if lock_has_input(&locks[&c], &path) {
                        continue;
                    }
                    let source = &f.source;
                    return Err(Failure::Message(if c == *name {
                        format!("error: source {name} draws input {input} from source {source}, but its flake has no input {input}")
                    } else {
                        format!(
                            "error: source {name} draws input {input} from source {source}, but the flake of source {c} has no input {}",
                            path.join("/")
                        )
                    }));
                }
            }
        }
        Ok(())
    }

    /// Rewrites the lock file of the flake in a file or git source in
    /// place.
    fn rewrite(&self, name: &str) -> Result<()> {
        let args = self.override_args(name)?;
        let resolved = self.resolve(&[self.path(name)], false)?;
        let url = Self::flake_url(name, &resolved[0])?;
        let mut all = vec![resolved[0].path.as_str(), url.as_str()];
        all.extend(args.iter().map(String::as_str));
        self.run(sh::draw::LOCK, true, &all)
    }

    /// Derives what the target path of a flake or flake-input source gets
    /// from what got delivered to .populate/derived/<name>/original: a
    /// copy, which gets patched and gets its lock file rewritten.  Unless
    /// materialized, the copy gets added to the store, and the target path
    /// becomes a link to it.  Copies get made again only if what they
    /// derive from changes: materialized ones if the delivered store path,
    /// the patches, or what inputs get drawn from which sources changes,
    /// and others also if the sources they draw inputs from change.  The
    /// key of a copy, in .populate/derived/<name>/key, is the hash of all
    /// that.
    fn derive(&self, name: &str) -> Result<()> {
        let settings = &self.sources[name].settings;
        let materialize = bool_setting(settings, "materialize", false);
        let rewrite_lock =
            bool_setting(settings, "rewriteLock", true) && self.drawing.contains(name);
        let target_path = self.path(name);
        let target_name = self.context.name(&target_path);
        let state = self.state("derived", name);
        let patch_dir = if patches(settings).is_empty() {
            String::new()
        } else {
            self.state("patches", name)
        };
        let args = if rewrite_lock {
            self.override_args(name)?
        } else {
            Vec::new()
        };
        // Sources outside the store can change without changing their
        // path.
        let drawn: Vec<String> = if rewrite_lock && !materialize {
            self.drawn_from(name)
                .iter()
                .map(|s| self.drawn_flake(s))
                .collect()
        } else {
            Vec::new()
        };

        let mut state_args = vec![state.as_str(), target_path.as_str(), patch_dir.as_str()];
        state_args.extend(drawn.iter().map(String::as_str));
        let fields = self.fields(sh::draw::DERIVED_STATE, false, &state_args)?;
        let malformed =
            || Failure::Message(format!("error: can't read the state of source {name}"));
        let [original, key_file, result, target_kind, rest @ ..] = fields.as_slice() else {
            return Err(malformed());
        };
        let separator = rest
            .iter()
            .position(String::is_empty)
            .ok_or_else(malformed)?;
        let (patch_sums, hashes) = (&rest[..separator], &rest[separator + 1..]);
        if hashes.len() != drawn.len() {
            return Err(malformed());
        }

        // Like Nix' toJSON: attributes sorted by name.
        let follows: Vec<Value> = self.follows[name]
            .iter()
            .map(|f| serde_json::json!({ "path": f.path, "source": f.source }))
            .collect();
        let spec = serde_json::json!({
            "follows": follows,
            "materialize": materialize,
            "rewriteLock": rewrite_lock,
        });
        let mut text = format!("{original}\n{spec}\n");
        for sum in patch_sums {
            text += &format!("{sum}\n");
        }
        if !drawn.is_empty() {
            for arg in &args {
                text += &format!("{arg}\n");
            }
            for hash in hashes.iter().filter(|h| !h.is_empty()) {
                text += &format!("{hash}\n");
            }
        }
        let key = sha256_hex(text.as_bytes());
        let unchanged = *key_file == key;

        if materialize {
            if !unchanged || target_kind != "directory" {
                let work = format!("{state}/work");
                let key_path = format!("{state}/key");
                self.run(
                    sh::draw::MATERIALIZE,
                    false,
                    &[
                        original,
                        &work,
                        &target_path,
                        &target_name,
                        &patch_dir,
                        name,
                        &key_path,
                        &key,
                    ],
                )?;
            }
            if rewrite_lock {
                let url = self.own_url(name)?;
                let mut all = vec![target_path.as_str(), url.as_str()];
                all.extend(args.iter().map(String::as_str));
                self.run(sh::draw::LOCK, true, &all)?;
            }
            return Ok(());
        }

        let (path, subdir) = split_store_path(original);
        let result = if unchanged { result.as_str() } else { "" };
        let mut all = vec![
            state.as_str(),
            path,
            subdir,
            &target_path,
            &target_name,
            result,
            &patch_dir,
            name,
            &key,
        ];
        all.extend(args.iter().map(String::as_str));
        self.run(sh::draw::ADD, rewrite_lock, &all)
    }

    /// Generates the flake of a source in .populate/flakes/<name>, which
    /// re-exports the outputs of the flake in the source, with inputs drawn
    /// from other sources.
    fn generate(&self, name: &str) -> Result<()> {
        let json = |s: &str| serde_json::to_string(s).expect("serializes");
        let url = self.own_url(name)?;
        let drawn = self.drawn_from(name);
        let urls = self.drawn_urls(&drawn)?;
        let mut text = format!(
            "{{\n  inputs.{}.url = \"{url}\";\n",
            json(&input_name(name))
        );
        for source in &drawn {
            let (url, flake) = &urls[*source];
            let input = json(&input_name(source));
            text += &format!("  inputs.{input}.url = \"{url}\";\n");
            if !flake {
                text += &format!("  inputs.{input}.flake = false;\n");
            }
        }
        // Nix ignores overrides below an input that follows another input,
        // so an input of an input drawn from a source gets overridden at
        // that source.
        for f in &self.follows[name] {
            let path: Vec<String> = drawn_path(name, &f.path, &self.follows, &self.generated)
                .iter()
                .map(|n| json(n))
                .collect();
            text += &format!(
                "  inputs.{}.follows = {};\n",
                path.join(".inputs."),
                json(&input_name(&f.source))
            );
        }
        text += &format!(
            "  outputs = inputs: inputs.{};\n}}\n",
            json(&input_name(name))
        );
        self.run(
            sh::draw::GENERATE,
            true,
            &[&self.state("flakes", name), &text],
        )
    }

    /// Removes the state that sources don't need anymore.
    fn clean_up(&self) -> Result<()> {
        let list = |names: &mut dyn Iterator<Item = &str>| names.collect::<Vec<_>>().join(" ");
        let all = list(&mut self.sources.keys().map(String::as_str));
        let not_flakes = list(
            &mut self
                .sources
                .iter()
                .filter(|(_, s)| !matches!(s.kind.as_str(), "flake" | "flake-input"))
                .map(|(n, _)| n.as_str()),
        );
        let generated = list(&mut self.generated.iter().copied());
        let derived = list(&mut self.derived.iter().copied());
        let patched = list(
            &mut self
                .sources
                .iter()
                .filter(|(_, s)| !patches(&s.settings).is_empty())
                .map(|(n, _)| n.as_str()),
        );
        self.run(
            sh::draw::CLEAN_UP,
            false,
            &[
                &self.sentinel(),
                &all,
                &not_flakes,
                &generated,
                &derived,
                &patched,
            ],
        )
    }
}

/// Draws inputs of flakes in sources from other sources, derives what the
/// target paths of flake and flake-input sources that get patched, get
/// their lock files rewritten, or are materialized get, and removes state
/// that sources don't need anymore.  Sources get processed in the order
/// they draw inputs from each other.
///
/// Inputs get drawn by rewriting the lock file of the flake in the source
/// with nix flake lock --override-input: in place for file and git sources,
/// and in a copy for flake and flake-input sources.  Sources with
/// rewriteLock set to false, and symlink sources, get a generated flake in
/// .populate/flakes/<name> instead, which re-exports the outputs of the
/// flake in the source, with those inputs drawn from the other sources.
/// Lock files get rewritten or generated on every run, so they match the
/// sources.
pub fn flakes(context: &Context, dir: &str, sources: &BTreeMap<String, Source>) -> Result<()> {
    let follows: BTreeMap<&str, Vec<Follows>> = sources
        .iter()
        .map(|(n, s)| (n.as_str(), s.follows()))
        .collect();
    let names_where = |p: &dyn Fn(&Source) -> bool| -> BTreeSet<&str> {
        sources
            .iter()
            .filter(|(_, s)| p(s))
            .map(|(n, _)| n.as_str())
            .collect()
    };
    let flakes = Flakes {
        context,
        dir,
        sources,
        drawing: names_where(&|s| !s.follows().is_empty()),
        generated: names_where(&has_generated_flake),
        derived: names_where(&derives_flake),
        follows,
    };
    let names: BTreeSet<&str> = flakes.drawing.union(&flakes.derived).copied().collect();
    if !names.is_empty() {
        let mut args = vec![flakes.sentinel()];
        args.extend(sources.keys().cloned());
        let args: Vec<&str> = args.iter().map(String::as_str).collect();
        flakes.run(sh::draw::USE_STATE, false, &args)?;
        if !flakes.drawing.is_empty() {
            flakes.check()?;
        }
        let drawn_from = |name: &str| -> Vec<String> {
            flakes.follows[name]
                .iter()
                .map(|f| f.source.clone())
                .collect()
        };
        for name in toposort(&names, &drawn_from) {
            if flakes.derived.contains(name) {
                flakes.derive(name)?;
            }
            if flakes.generated.contains(name) {
                flakes.generate(name)?;
            } else if flakes.drawing.contains(name) && !flakes.derived.contains(name) {
                flakes.rewrite(name)?;
            }
        }
    }
    flakes.clean_up()
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
    use serde_json::json;

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

    #[test]
    fn url_paths() {
        assert_eq!(url_path("/var/src/a-b_c.d~e"), "/var/src/a-b_c.d~e");
        assert_eq!(url_path("/x y?#%"), "/x%20y%3f%23%25");
        assert_eq!(url_path("/ä"), "/%c3%a4");
    }

    #[test]
    fn input_names() {
        assert_eq!(input_name("nixpkgs"), "nixpkgs");
        assert_eq!(
            input_name("self"),
            format!("source-{}", &sha256_hex(b"self")[..16])
        );
        assert!(input_name("1x").starts_with("source-"));
        assert!(input_name("a.b").starts_with("source-"));
    }

    #[test]
    fn store_paths() {
        assert_eq!(
            split_store_path("/nix/store/abc-source/sub/dir"),
            ("/nix/store/abc-source", "sub/dir")
        );
        assert_eq!(
            split_store_path("/nix/store/abc-source"),
            ("/nix/store/abc-source", "")
        );
    }

    fn path(names: &[&str]) -> Vec<String> {
        names.iter().map(|n| n.to_string()).collect()
    }

    /// A lock file with inputs a and b, where a has an input c, and its
    /// input b follows the root's b.
    fn locks() -> Value {
        json!({
            "root": "root",
            "nodes": {
                "root": { "inputs": { "a": "a", "b": "b_2" } },
                "a": { "inputs": { "b": ["b"], "c": "c", "gone": [] } },
                "b_2": { "inputs": { "d": "d" } },
                "c": {},
                "d": {}
            }
        })
    }

    #[test]
    fn lock_inputs() {
        let locks = locks();
        assert!(lock_has_input(&locks, &path(&[])));
        assert!(lock_has_input(&locks, &path(&["a"])));
        assert!(lock_has_input(&locks, &path(&["a", "c"])));
        assert!(lock_has_input(&locks, &path(&["a", "b", "d"])));
        assert!(!lock_has_input(&locks, &path(&["x"])));
        assert!(!lock_has_input(&locks, &path(&["a", "x"])));
        assert!(!lock_has_input(&locks, &path(&["a", "b", "x"])));
        // An empty follows path refers to the root.
        assert!(lock_has_input(&locks, &path(&["a", "gone", "a"])));
    }

    #[test]
    fn cyclic_follows() {
        let mut locks = locks();
        locks["nodes"]["a"]["inputs"]["b"] = json!(["a", "b"]);
        assert!(!lock_has_input(&locks, &path(&["a", "b"])));
    }

    /// A source's name, and the paths of the inputs it draws, with the
    /// sources it draws them from.
    type Entry<'a> = (&'a str, &'a [(&'a [&'a str], &'a str)]);

    fn follows(entries: &[Entry]) -> BTreeMap<&'static str, Vec<Follows>> {
        entries
            .iter()
            .map(|(name, fs)| {
                let name: &'static str = Box::leak(name.to_string().into_boxed_str());
                let fs = fs
                    .iter()
                    .map(|(p, s)| Follows {
                        path: path(p),
                        source: s.to_string(),
                    })
                    .collect();
                (name, fs)
            })
            .collect()
    }

    #[test]
    fn drawn_paths() {
        // top draws dep from source dep, and dep's inner from source
        // inner; dep draws nothing itself.
        let follows = follows(&[
            ("top", &[(&["dep"], "dep"), (&["dep", "inner"], "inner")]),
            ("dep", &[]),
            ("inner", &[]),
        ]);
        let none = BTreeSet::new();
        assert_eq!(
            drawn_path("top", &path(&["dep", "inner"]), &follows, &none),
            path(&["dep", "inner"])
        );
        let generated: BTreeSet<&str> = ["top"].into();
        assert_eq!(
            drawn_path("top", &path(&["dep"]), &follows, &generated),
            path(&["top", "dep"])
        );
        assert_eq!(
            drawn_path("top", &path(&["dep", "inner"]), &follows, &generated),
            path(&["dep", "inner"])
        );
        assert_eq!(
            input_checks("top", &path(&["dep", "inner"]), &follows),
            vec![
                ("top".to_string(), path(&["dep"])),
                ("dep".to_string(), path(&["inner"]))
            ]
        );
    }
}
