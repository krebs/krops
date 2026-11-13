//! Checks of the spec, the same as checks.nix makes during evaluation, so a
//! spec from anywhere else gets checked as well.  Messages are the same.

use crate::spec::{Source, Spec};
use serde_json::{Map, Value};
use std::collections::BTreeMap;

/// The spec's checks in the order checks.nix makes them, the first failing
/// one's message.
pub fn spec(spec: &Spec) -> Result<(), String> {
    target_path(&spec.target.path)?;
    for (name, source) in &spec.source {
        source_name(name)?;
        settings(name, source)?;
    }
    inputs(&spec.source)
}

/// What a setting holds.
#[derive(Clone, Copy)]
enum Kind {
    Bool,
    String,
    /// A path starting with /, as lib.types.absolute-pathname and
    /// lib.types.path demand.
    Absolute,
    Absolutes,
    Strings,
    /// git's clean, with exclude, a list of strings.
    Clean,
    /// file's filters, each with type include or exclude, and a pattern.
    Filters,
    /// Inputs drawn from other sources, each with follows, a string, and
    /// inputs, again inputs.
    Inputs,
}

/// The settings of each source type, as lib/types/populate.nix defines
/// them, and whether a source needs them, because they have no default.
fn known_settings(kind: &str) -> &'static [(&'static str, Kind, bool)] {
    use Kind::*;
    match kind {
        "derivation" => &[("text", String, true)],
        "file" => &[
            ("path", Absolute, true),
            ("useChecksum", Bool, false),
            ("exclude", Strings, false),
            ("filters", Filters, false),
            ("deleteExcluded", Bool, false),
            ("insecureLinks", Bool, false),
            ("inputs", Inputs, false),
            ("rewriteLock", Bool, false),
        ],
        "flake" => &[
            ("url", String, true),
            ("fetchOnTarget", Bool, false),
            ("inputs", Inputs, false),
            ("materialize", Bool, false),
            ("patches", Absolutes, false),
            ("rewriteLock", Bool, false),
        ],
        "flake-input" => &[
            ("url", String, true),
            ("name", String, true),
            ("requireInputs", Bool, false),
            ("fetchOnTarget", Bool, false),
            ("inputs", Inputs, false),
            ("materialize", Bool, false),
            ("patches", Absolutes, false),
            ("rewriteLock", Bool, false),
        ],
        "git" => &[
            ("url", String, true),
            ("ref", String, true),
            ("clean", Clean, false),
            ("fetchAlways", Bool, false),
            ("shallow", Bool, false),
            ("reclone", Bool, false),
            ("inputs", Inputs, false),
            ("rewriteLock", Bool, false),
        ],
        "pass" => &[("dir", Absolute, true), ("name", String, true)],
        "passage" => &[
            ("age", String, true),
            ("dir", String, true),
            ("identities_file", String, true),
        ],
        "pipe" => &[("command", Absolute, true)],
        "symlink" => &[("target", String, true), ("inputs", Inputs, false)],
        _ => &[],
    }
}

/// Whether value is what kind says.
fn is_kind(value: &Value, kind: Kind) -> bool {
    let absolute = |v: &Value| v.as_str().is_some_and(|s| s.starts_with('/'));
    let strings = |v: &Value| {
        v.as_array()
            .is_some_and(|a| a.iter().all(|x| x.is_string()))
    };
    let only = |o: &Map<String, Value>, keys: &[&str]| o.keys().all(|k| keys.contains(&k.as_str()));
    match kind {
        Kind::Bool => value.is_boolean(),
        Kind::String => value.is_string(),
        Kind::Absolute => absolute(value),
        Kind::Absolutes => value.as_array().is_some_and(|a| a.iter().all(absolute)),
        Kind::Strings => strings(value),
        Kind::Clean => value
            .as_object()
            .is_some_and(|o| only(o, &["exclude"]) && o.get("exclude").map_or(true, strings)),
        Kind::Filters => value.as_array().is_some_and(|a| {
            a.iter().all(|f| {
                f.as_object().is_some_and(|o| {
                    only(o, &["type", "pattern"])
                        && matches!(
                            o.get("type").and_then(Value::as_str),
                            None | Some("include" | "exclude")
                        )
                        && o.get("pattern").is_some_and(Value::is_string)
                })
            })
        }),
        Kind::Inputs => value.as_object().is_some_and(|inputs| {
            inputs.values().all(|input| {
                input.as_object().is_some_and(|o| {
                    only(o, &["follows", "inputs"])
                        && o.get("follows").map_or(true, Value::is_string)
                        && o.get("inputs").map_or(true, |i| is_kind(i, Kind::Inputs))
                })
            })
        }),
    }
}

/// The settings of a source are those of its type, of the kinds
/// lib/types/populate.nix demands, so a misspelt one doesn't go unnoticed,
/// and paths populate passes to commands can't be taken for options.
pub fn settings(name: &str, source: &Source) -> Result<(), String> {
    let kind = &source.kind;
    let known = known_settings(kind);
    for key in source.settings.keys() {
        if !known.iter().any(|(k, _, _)| k == key) {
            return Err(format!(
                "krops: source {name}: a {kind} source has no setting {key}"
            ));
        }
    }
    for (key, setting, required) in known {
        match source.settings.get(*key) {
            None if *required => {
                return Err(format!(
                    "krops: source {name}: a {kind} source needs the setting {key}"
                ))
            }
            None => {}
            Some(value) if is_kind(value, *setting) => {}
            Some(value) if matches!(setting, Kind::Absolute) && value.is_string() => {
                return Err(format!(
                    "krops: source {name}: the {key} of a {kind} source must be an absolute path, not {}",
                    value
                ))
            }
            Some(value) => {
                return Err(format!(
                    "krops: source {name}: the {key} of a {kind} source can't be {value}"
                ))
            }
        }
    }
    Ok(())
}

/// Like JSON, the way Nix' toJSON quotes strings in messages.
fn quote(s: &str) -> String {
    serde_json::to_string(s).expect("strings serialize")
}

/// Populate replaces and removes what's at the target paths of sources, so
/// it refuses names that lead out of the target directory, to the directory
/// itself, or to its own state.  The remaining names are portable file
/// names.
pub fn source_name(name: &str) -> Result<(), String> {
    let portable = |c: char| c.is_ascii_alphanumeric() || c == '.' || c == '_' || c == '-';
    let ok = !matches!(name, "." | ".." | ".populate")
        && !name.is_empty()
        && !name.starts_with('-')
        && name.chars().all(portable);
    if ok {
        Ok(())
    } else {
        Err(format!(
            "krops: source name {} can't be used: it must consist of letters, digits, and the characters ._-, not start with -, and be neither ., .., nor .populate",
            quote(name)
        ))
    }
}

/// Populate removes what it finds in the target directory, so it refuses
/// paths that aren't absolute, that are the root directory, or that the
/// target would resolve to another directory than the one they name.
pub fn target_path(path: &str) -> Result<(), String> {
    let fail = |why: &str| {
        Err(format!(
            "krops: target path {} can't be used: {why}",
            quote(path)
        ))
    };
    let components: Vec<&str> = path
        .split('/')
        .filter(|c| !c.is_empty() && *c != ".")
        .collect();
    if !path.starts_with('/') {
        fail("it must be absolute")
    } else if components.is_empty() {
        fail("it must not be the root directory")
    } else if components.contains(&"..") || path.chars().any(|c| c.is_ascii_control()) {
        fail("it must not contain .. or control characters")
    } else {
        Ok(())
    }
}

/// Inputs get drawn from other sources, so they must exist, and drawing
/// must not go round in circles.
pub fn inputs(sources: &BTreeMap<String, Source>) -> Result<(), String> {
    let drawn_from: BTreeMap<&str, Vec<String>> = sources
        .iter()
        .map(|(name, source)| {
            (
                name.as_str(),
                source.follows().into_iter().map(|f| f.source).collect(),
            )
        })
        .collect();
    for (name, froms) in &drawn_from {
        for from in froms {
            if from == name {
                return Err(format!("krops: source {name} draws inputs from itself"));
            }
            if !sources.contains_key(from) {
                return Err(format!(
                    "krops: source {name} draws inputs from missing source {from}"
                ));
            }
        }
    }
    // Depth-first search, with the path of sources on the way, which repeats
    // a source if drawing goes round in circles.  The message names the
    // whole path, the way into the circle included, like checks.nix.
    fn visit<'a>(
        name: &'a str,
        drawn_from: &'a BTreeMap<&str, Vec<String>>,
        done: &mut Vec<&'a str>,
        path: &mut Vec<&'a str>,
    ) -> Result<(), String> {
        if path.contains(&name) {
            return Err(format!(
                "krops: sources draw inputs from each other: {}",
                path.join(" ")
            ));
        }
        if done.contains(&name) {
            return Ok(());
        }
        path.push(name);
        for from in &drawn_from[name] {
            visit(from, drawn_from, done, path)?;
        }
        path.pop();
        done.push(name);
        Ok(())
    }
    let mut done = Vec::new();
    for name in drawn_from.keys() {
        visit(name, &drawn_from, &mut done, &mut Vec::new())?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn source_names() {
        for name in ["a", "A.b_c-d", ".x", "_", "0"] {
            assert!(source_name(name).is_ok(), "{name:?}");
        }
        for name in [
            "",
            ".",
            "..",
            ".populate",
            "a/b",
            "../x",
            "/etc",
            "a\nb",
            "a b",
            "a*b",
            "a?b",
            "a+b",
            "a=b",
            "-a",
        ] {
            assert!(source_name(name).is_err(), "{name:?}");
        }
    }

    #[test]
    fn target_paths() {
        for path in ["/a", "/var/src", "/a/./b", "//a"] {
            assert!(target_path(path).is_ok(), "{path:?}");
        }
        for path in [
            "",
            "/",
            "//",
            "/.",
            "relative",
            "/var/krops/..",
            "/var/krops/../..",
            "/var/krops/a\nb",
        ] {
            assert!(target_path(path).is_err(), "{path:?}");
        }
        assert_eq!(
            target_path("/a\nb").unwrap_err(),
            r#"krops: target path "/a\nb" can't be used: it must not contain .. or control characters"#
        );
    }

    fn sources(json: &str) -> BTreeMap<String, Source> {
        serde_json::from_str(json).unwrap()
    }

    #[test]
    fn drawing_inputs() {
        let ok = sources(
            r#"{
            "a": {"type": "file", "file": {"path": "/a", "inputs": {"x": {"follows": "b"}}}},
            "b": {"type": "file", "file": {"path": "/b"}}
        }"#,
        );
        assert!(inputs(&ok).is_ok());
        let missing = sources(
            r#"{
            "a": {"type": "file", "file": {"path": "/a", "inputs": {"x": {"follows": "c"}}}}
        }"#,
        );
        assert_eq!(
            inputs(&missing).unwrap_err(),
            "krops: source a draws inputs from missing source c"
        );
        let cycle = sources(
            r#"{
            "a": {"type": "file", "file": {"path": "/a", "inputs": {"x": {"follows": "b"}}}},
            "b": {"type": "file", "file": {"path": "/b",
                  "inputs": {"y": {"inputs": {"z": {"follows": "a"}}}}}}
        }"#,
        );
        assert_eq!(
            inputs(&cycle).unwrap_err(),
            "krops: sources draw inputs from each other: a b"
        );
    }

    #[test]
    fn settings() {
        let spec = |file: &str| -> Spec {
            serde_json::from_str(&format!(
                r#"{{"version": 1, "target": {{"host": "h", "path": "/a"}},
                    "source": {{"x": {{"type": "file", "file": {}}}}}}}"#,
                file
            ))
            .unwrap()
        };
        assert!(super::spec(&spec(r#"{"path": "/src"}"#)).is_ok());
        assert!(super::spec(&spec(r#"{"path": "--rsync-path=x"}"#)).is_err());
        assert_eq!(
            super::spec(&spec(r#"{"path": "relative"}"#)).unwrap_err(),
            r#"krops: source x: the path of a file source must be an absolute path, not "relative""#
        );
        assert_eq!(
            super::spec(&spec(r#"{"path": "/src", "deleteExcludd": false}"#)).unwrap_err(),
            "krops: source x: a file source has no setting deleteExcludd"
        );
        assert_eq!(
            super::spec(&spec(r#"{"path": "/src", "useChecksum": "yes"}"#)).unwrap_err(),
            r#"krops: source x: the useChecksum of a file source can't be "yes""#
        );
        assert_eq!(
            super::spec(&spec("{}")).unwrap_err(),
            "krops: source x: a file source needs the setting path"
        );
        assert!(super::spec(&spec(
            r#"{"path": "/src", "filters": [{"type": "include", "pattern": "*.nix"}],
                "inputs": {"a": {"follows": "x", "inputs": {"b": {"follows": "y"}}}}}"#
        ))
        .is_err_and(|e| e.contains("draws inputs")));
        assert!(super::spec(&spec(
            r#"{"path": "/src", "filters": [{"type": "x", "pattern": "*"}]}"#
        ))
        .is_err_and(|e| e.contains("filters")));
    }

    #[test]
    fn cycle_reached_from_another_source() {
        let cycle = sources(
            r#"{
            "a": {"type": "file", "file": {"path": "/a", "inputs": {"i": {"follows": "b"}}}},
            "b": {"type": "file", "file": {"path": "/b", "inputs": {"i": {"follows": "c"}}}},
            "c": {"type": "file", "file": {"path": "/c", "inputs": {"i": {"follows": "b"}}}}
        }"#,
        );
        assert_eq!(
            inputs(&cycle).unwrap_err(),
            "krops: sources draw inputs from each other: a b c"
        );
    }
}
