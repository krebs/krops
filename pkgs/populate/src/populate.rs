//! Delivering the sources of a spec.

use crate::flake;
use crate::rsync::{self, Config};
use crate::run::{self, Context, Failure, Result};
use crate::sh;
use crate::spec::{Source, Spec};
use serde_json::{Map, Value};
use std::fs;
use std::path::PathBuf;
use std::process::Command;

/// Checks the sentinel, makes a backup if asked, delivers each source, and
/// prunes if asked.
pub fn populate(context: &Context, spec: &Spec) -> Result<()> {
    let dir = &spec.target.path;
    refuse_copying_with_sudo(context, spec)?;
    let sentinel = format!("{dir}/.populate");
    let force = if spec.force { "1" } else { "" };
    context.run(
        sh::CHECK,
        &[&sentinel, &context.name(&sentinel), dir, force],
    )?;
    if spec.backup {
        context.run(&sh::backup(), &[dir, &context.name(&sentinel)])?;
    }
    for (name, source) in &spec.source {
        let path = format!("{dir}/{name}");
        eprintln!("populating '{}'...", context.name(&path));
        let workdir = context.tmpdir.join("workdirs").join(name);
        fs::create_dir_all(&workdir).map_err(|e| {
            Failure::Message(format!("error: can't create {}: {e}", workdir.display()))
        })?;
        deliver(context, name, source, &path, workdir)?;
    }
    context.run(&flake::flakes(context, dir, &spec.source), &[])?;
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
        context.run(&sh::prune(), &args)?;
    }
    Ok(())
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

/// Delivers a source to path on the target, using workdir for files it
/// prepares on the deploying machine.
fn deliver(
    context: &Context,
    name: &str,
    source: &Source,
    path: &str,
    workdir: PathBuf,
) -> Result<()> {
    let settings = &source.settings;
    match source.kind.as_str() {
        "derivation" => context.run(
            &sh::derivation(),
            &[path, &context.name(path), string(settings, "text")?],
        ),
        "file" => {
            let source_path = string(settings, "path")?;
            // Store paths have the same time, so only checksums tell
            // different contents apart.
            let use_checksum = settings
                .get("useChecksum")
                .and_then(Value::as_bool)
                .unwrap_or(run::is_store_path(source_path));
            let config = Config {
                use_checksum,
                ..Config::from_settings(settings)
            };
            rsync::transfer(context, &config, source_path, path)
        }
        "pipe" => {
            let out = workdir.join("out");
            let file = fs::File::create(&out).map_err(|e| {
                Failure::Message(format!("error: can't create {}: {e}", out.display()))
            })?;
            run::status(
                Command::new(string(settings, "command")?)
                    .current_dir(&workdir)
                    .stdout(file),
            )?;
            run::status(
                Command::new("touch")
                    .arg("-t")
                    .arg("300001010000")
                    .arg(&out),
            )?;
            // With the fixed modification time, only checksums tell outputs
            // of the same size apart.
            let config = Config {
                use_checksum: true,
                ..Config::default()
            };
            rsync::transfer(context, &config, &out.to_string_lossy(), path)
        }
        "flake" | "flake-input" => run::status(&mut run::local_shell(
            &flake::flake_input(context, name, path, source),
            &[],
            &workdir,
        )),
        "git" => {
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
            let name = context.name(path);
            let mut args = vec![
                path,
                &name,
                string(settings, "url")?,
                string(settings, "ref")?,
                flag("shallow"),
                flag("fetchAlways"),
                flag("reclone"),
            ];
            args.extend(excludes);
            context.run(&sh::git(), &args)
        }
        "pass" => {
            let dir = string(settings, "dir")?;
            let name = string(settings, "name")?;
            let info = run::output(&mut run::local_shell(
                sh::local::PASS_INFO,
                &[dir, name],
                &workdir,
            ))?;
            let info = info.trim_end_matches('\n');
            if !info.is_empty() {
                let delivered = context.output(sh::PASS_INFO, &[path])?;
                if delivered.trim_end_matches('\n') == info {
                    return Ok(());
                }
            }
            run::status(&mut run::local_shell(
                sh::local::PASS,
                &[dir, name, info],
                &workdir,
            ))?;
            rsync::transfer(
                context,
                &Config::default(),
                &workdir.to_string_lossy(),
                path,
            )
        }
        "passage" => {
            let host = context.target.host.split('.').next().unwrap_or_default();
            let mut command = run::local_shell(sh::local::PASSAGE, &[host], &workdir);
            for (variable, key) in [
                ("PASSAGE_AGE", "age"),
                ("PASSAGE_DIR", "dir"),
                ("PASSAGE_IDENTITIES_FILE", "identities_file"),
            ] {
                command.env(variable, string(settings, key)?);
            }
            run::status(&mut command)?;
            rsync::transfer(
                context,
                &Config::default(),
                &workdir.to_string_lossy(),
                path,
            )
        }
        "symlink" => context.run(sh::SYMLINK, &[path, string(settings, "target")?]),
        // The spec's types are all of the above.
        kind => Err(Failure::Message(format!(
            "populate: unknown source type {kind}"
        ))),
    }
}
