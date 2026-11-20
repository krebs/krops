//! Delivering the sources of a spec.

use crate::flake;
use crate::flake_input;
use crate::record;
use crate::rsync::{self, Config};
use crate::run::{self, Context, Failure, Result};
use crate::sh;
use crate::spec::{Source, Spec};
use serde_json::{json, Map, Value};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

/// Checks the sentinel, takes the lock on the target directory, makes a
/// backup if asked, delivers each source, prunes if asked, and writes the
/// record of the run, see the record module.
pub fn populate(context: &Context, spec: &Spec) -> Result<()> {
    let dir = &spec.target.path;
    refuse_copying_with_sudo(context, spec)?;
    let sentinel = format!("{dir}/.populate");
    let force = if spec.force { "1" } else { "" };
    context.run(
        sh::CHECK,
        &[&sentinel, &context.name(&sentinel), dir, force],
    )?;
    let started = record::now();
    let (previous, last) = context.lock(&sentinel, json!({ "run": started }))?;
    if spec.backup {
        context.run(&sh::backup(), &[dir])?;
    }
    for (name, source) in &spec.source {
        let path = format!("{dir}/{name}");
        eprintln!("populating '{}'...", context.name(&path));
        let workdir = context.tmpdir.join("workdirs").join(name);
        fs::create_dir_all(&workdir).map_err(|e| {
            Failure::Message(format!("error: can't create {}: {e}", workdir.display()))
        })?;
        let Some(kind) = kind(&source.kind) else {
            // The spec's types are all known.
            return Err(Failure::Message(format!(
                "populate: unknown source type {}",
                source.kind
            )));
        };
        let delivery = Delivery {
            context,
            name,
            source,
            path: &path,
            workdir,
        };
        context.note(json!({ "begin": name }));
        let outcome = kind.deliver(&delivery)?;
        outcome.note(context, name);
    }
    flake::flakes(context, dir, &spec.source)?;
    if spec.prune {
        let flakes = spec
            .source
            .iter()
            .filter(|(_, source)| matches!(source.kind.as_str(), "flake" | "flake-input"))
            .map(|(name, _)| name.as_str());
        let mut args = vec![dir.as_str()];
        let log = context.name(dir);
        args.push(&log);
        args.extend(spec.source.keys().map(String::as_str));
        args.push("--");
        args.extend(flakes);
        if context.output(&sh::prune(), &args)?.contains("pruned") {
            context.note(json!({ "pruned": true }));
        }
    }
    let mut record = record::record(spec, &started, &previous, &context.entries());
    digests(context, spec, &mut record, &last.join("\n"))?;
    context.run(sh::RECORD, &[&sentinel, &record.to_string()])?;
    context.unlock();
    Ok(())
}

/// Adds the digest of each file source whose record setting asks for it to
/// the record: of what's at its target path now, after the flakes step,
/// only if it changed since the last record, last, and else the one the
/// last record has, so a run that changes nothing reads nothing more.
fn digests(context: &Context, spec: &Spec, record: &mut Value, last: &str) -> Result<()> {
    let last: Value = serde_json::from_str(last).unwrap_or(Value::Null);
    let mut names = Vec::new();
    let mut paths = Vec::new();
    for (name, source) in &spec.source {
        if !record_setting(source, "digest") {
            continue;
        }
        let entry = &mut record["sources"][name];
        let digest = &last["sources"][name]["digest"];
        if entry["changed"] == json!(false) && digest.is_string() {
            entry["digest"] = digest.clone();
        } else {
            names.push(name);
            paths.push(format!("{}/{name}", spec.target.path));
        }
    }
    if !paths.is_empty() {
        let args: Vec<&str> = paths.iter().map(String::as_str).collect();
        let output = context.output(sh::DIGESTS, &args)?;
        for (name, digest) in names.iter().zip(output.lines()) {
            record["sources"][name.as_str()]["digest"] = json!(digest);
        }
    }
    Ok(())
}

/// Whether a source's record setting has key set.
fn record_setting(source: &Source, key: &str) -> bool {
    source
        .settings
        .get("record")
        .and_then(|r| r.get(key))
        .and_then(Value::as_bool)
        == Some(true)
}

/// What delivering a source did: whether that changed anything in the
/// target directory, and what got delivered, for the record of the run.
#[derive(Default)]
pub struct Outcome {
    pub changed: bool,
    pub delivered: Map<String, Value>,
}

impl Outcome {
    pub fn changed(changed: bool) -> Outcome {
        Outcome {
            changed,
            ..Outcome::default()
        }
    }

    /// With what got delivered, under key, as value.
    pub fn with(mut self, key: &str, value: impl Into<Value>) -> Outcome {
        self.delivered.insert(key.to_string(), value.into());
        self
    }

    /// Notes the outcome in the journal, ending what began for the source
    /// name.
    pub fn note(self, context: &Context, name: &str) {
        context.note(json!({
            "end": name,
            "changed": self.changed,
            "delivered": self.delivered,
        }));
    }
}

/// A source to deliver, and where.
struct Delivery<'a> {
    context: &'a Context,
    name: &'a str,
    source: &'a Source,
    /// The target path.
    path: &'a str,
    /// Where to prepare files on the deploying machine.
    workdir: PathBuf,
}

impl Delivery<'_> {
    fn string(&self, key: &str) -> Result<&str> {
        string(&self.source.settings, key)
    }

    /// Transfers source_path, prepared on the deploying machine, to the
    /// target path, with rsync's default configuration.
    fn transfer(&self, source_path: &Path) -> Result<Outcome> {
        let changed = rsync::transfer(
            self.context,
            &Config::default(),
            &source_path.to_string_lossy(),
            self.path,
        )?;
        Ok(Outcome::changed(!changed.is_empty()))
    }
}

/// A type of source.
trait Kind {
    /// Delivers the source.
    fn deliver(&self, delivery: &Delivery) -> Result<Outcome>;
}

/// The type of source named kind.
fn kind(kind: &str) -> Option<&'static dyn Kind> {
    Some(match kind {
        "derivation" => &Derivation,
        "file" => &File,
        "pipe" => &Pipe,
        "flake" | "flake-input" => &Flake,
        "git" => &Git,
        "pass" => &Pass,
        "passage" => &Passage,
        "symlink" => &Symlink,
        _ => return None,
    })
}

/// Fails, before changing anything, if flakes would get copied to a remote
/// target using sudo, which nix copy doesn't support: it logs in as the
/// target's user.
fn refuse_copying_with_sudo(context: &Context, spec: &Spec) -> Result<()> {
    for (name, source) in &spec.source {
        let copying = matches!(source.kind.as_str(), "flake" | "flake-input")
            && source
                .settings
                .get("fetchOnTarget")
                .and_then(Value::as_bool)
                != Some(true);
        if copying && context.target.sudo && !context.local {
            return Err(Failure::Message(format!(
                "krops: source {}/{name}: copying flakes to targets with sudo is not supported",
                spec.target.path
            )));
        }
    }
    Ok(())
}

fn string<'a>(settings: &'a Map<String, Value>, key: &str) -> Result<&'a str> {
    settings
        .get(key)
        .and_then(Value::as_str)
        .ok_or_else(|| Failure::Message(format!("populate: the source has no {key}")))
}

/// The path, relative to the source, of the lock file of the flake in a
/// source, if the flakes step rewrites it in place, see flake::rewrite.
fn in_place_lock(source: &Source) -> Option<&'static str> {
    flake::rewrites_lock(source).then_some("flake.lock")
}

/// A Nix expression, built on the target, delivered as a link to the result.
struct Derivation;

impl Kind for Derivation {
    fn deliver(&self, d: &Delivery) -> Result<Outcome> {
        let output = d.context.output(
            &sh::derivation(),
            &[d.path, &d.context.name(d.path), d.string("text")?],
        )?;
        let mut lines = output.lines();
        let store_path = lines.next().unwrap_or_default();
        Ok(Outcome::changed(lines.any(|line| line == "changed")).with("storePath", store_path))
    }
}

/// A file or directory on the deploying machine.
struct File;

impl Kind for File {
    fn deliver(&self, d: &Delivery) -> Result<Outcome> {
        let settings = &d.source.settings;
        let source_path = d.string("path")?;
        // Store paths have the same time, so only checksums tell different
        // contents apart.
        let use_checksum = settings
            .get("useChecksum")
            .and_then(Value::as_bool)
            .unwrap_or(run::is_store_path(source_path));
        let config = Config {
            use_checksum,
            ..Config::from_settings(settings)
        };
        let changed = rsync::transfer(d.context, &config, source_path, d.path)?;
        // The lock file the flakes step rewrites, which delivering brings
        // back, changed if the flakes step says so.
        let lock = in_place_lock(d.source);
        let outcome = Outcome::changed(changed.iter().any(|path| Some(path.as_str()) != lock));
        if !record_setting(d.source, "commit") {
            return Ok(outcome);
        }
        // What the work tree's Git says, without its hooks and file system
        // monitors, and without writing the index.
        let git = |args: &[&str]| {
            Command::new("git")
                .args([
                    "-c",
                    "core.hooksPath=/dev/null",
                    "-c",
                    "core.fsmonitor=false",
                ])
                .args(["--no-optional-locks", "-C", source_path])
                .args(args)
                .stdin(Stdio::null())
                .stderr(Stdio::null())
                .output()
                .ok()
                .filter(|output| output.status.success())
                .map(|output| {
                    String::from_utf8_lossy(&output.stdout)
                        .trim_end()
                        .to_string()
                })
        };
        // Nothing, if the path isn't in a Git work tree.
        let Some(commit) = git(&["rev-parse", "--verify", "--quiet", "HEAD"]) else {
            return Ok(outcome);
        };
        let status = git(&["status", "--porcelain", "--", "."]).ok_or_else(|| {
            Failure::Message(format!("error: can't tell the Git status of {source_path}"))
        })?;
        Ok(outcome
            .with("commit", commit)
            .with("dirty", !status.is_empty()))
    }
}

/// What a command on the deploying machine prints.
struct Pipe;

impl Kind for Pipe {
    fn deliver(&self, d: &Delivery) -> Result<Outcome> {
        let out = d.workdir.join("out");
        let file = fs::File::create(&out)
            .map_err(|e| Failure::Message(format!("error: can't create {}: {e}", out.display())))?;
        // Through a shell, which runs a command without #! as a script.
        run::status(
            run::local_shell("\"$1\"\n", &[d.string("command")?], &d.workdir).stdout(file),
        )?;
        run::status(
            Command::new("touch")
                .arg("-t")
                .arg("300001010000")
                .arg(&out),
        )?;
        // With the fixed modification time, only checksums tell outputs of
        // the same size apart.
        let config = Config {
            use_checksum: true,
            ..Config::default()
        };
        let changed = rsync::transfer(d.context, &config, &out.to_string_lossy(), d.path)?;
        Ok(Outcome::changed(!changed.is_empty()))
    }
}

/// A flake, or an input of one, delivered as a link into the store.
struct Flake;

impl Kind for Flake {
    fn deliver(&self, d: &Delivery) -> Result<Outcome> {
        flake_input::deliver(d.context, d.name, d.path, d.source, &d.workdir)
    }
}

/// A Git work tree, with a commit checked out.
struct Git;

impl Kind for Git {
    fn deliver(&self, d: &Delivery) -> Result<Outcome> {
        let settings = &d.source.settings;
        let flag = |key| match settings.get(key).and_then(Value::as_bool) {
            Some(true) => "1",
            _ => "",
        };
        let excludes = settings
            .get("clean")
            .and_then(|clean| clean.get("exclude"))
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(Value::as_str);
        let name = d.context.name(d.path);
        let mut args = vec![
            d.path,
            &name,
            d.string("url")?,
            d.string("ref")?,
            flag("shallow"),
            flag("fetchAlways"),
            flag("reclone"),
            in_place_lock(d.source).unwrap_or_default(),
        ];
        args.extend(excludes);
        // With standard input, which Git may ask for credentials on.
        let mut command = d.context.shell(&sh::git(), &args)?;
        command.stdin(Stdio::inherit());
        let output = run::output(&mut command)?;
        let mut outcome = Outcome::default();
        for line in output.lines() {
            match line.split_once(' ') {
                Some(("commit", commit)) => outcome = outcome.with("commit", commit),
                _ if line == "checked" => d.context.git_checked(d.path),
                _ if line == "changed" => outcome.changed = true,
                _ => {}
            }
        }
        Ok(outcome)
    }
}

/// A secret from pass, decrypted on the deploying machine.
struct Pass;

impl Kind for Pass {
    fn deliver(&self, d: &Delivery) -> Result<Outcome> {
        let dir = d.string("dir")?;
        let name = d.string("name")?;
        let info = run::output(&mut run::local_shell(
            sh::local::PASS_INFO,
            &[dir, name],
            &d.workdir,
        ))?;
        let info = info.trim_end_matches('\n');
        if !info.is_empty() {
            let delivered = d.context.output(sh::PASS_INFO, &[d.path])?;
            if delivered.trim_end_matches('\n') == info {
                return Ok(Outcome::changed(false));
            }
        }
        run::status(&mut run::local_shell(
            sh::local::PASS,
            &[dir, name, info],
            &d.workdir,
        ))?;
        d.transfer(&d.workdir)
    }
}

/// Secrets from passage, decrypted on the deploying machine.
struct Passage;

impl Kind for Passage {
    fn deliver(&self, d: &Delivery) -> Result<Outcome> {
        let host = d.context.target.host.split('.').next().unwrap_or_default();
        let mut command = run::local_shell(sh::local::PASSAGE, &[host], &d.workdir);
        for (variable, key) in [("PASSAGE_AGE", "age"), ("PASSAGE_DIR", "dir")] {
            command.env(variable, d.string(key)?);
        }
        let identities =
            match d
                .source
                .settings
                .get("identities_file")
                .and_then(Value::as_str)
            {
                Some(file) => file.to_string(),
                None => match std::env::var("HOME") {
                    Ok(home) if !home.is_empty() => format!("{home}/.passage/identities"),
                    _ => return Err(Failure::Message(
                        "populate: HOME isn't set, so the passage source has no identities_file"
                            .to_string(),
                    )),
                },
            };
        command.env("PASSAGE_IDENTITIES_FILE", identities);
        run::status(&mut command)?;
        d.transfer(&d.workdir)
    }
}

/// A symlink.
struct Symlink;

impl Kind for Symlink {
    fn deliver(&self, d: &Delivery) -> Result<Outcome> {
        let target = d.string("target")?;
        let output = d.context.output(sh::SYMLINK, &[d.path, target])?;
        Ok(Outcome::changed(output.contains("changed")).with("target", target))
    }
}
