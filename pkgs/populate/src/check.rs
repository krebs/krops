//! Checks of the spec, the same as checks.nix makes during evaluation, so a
//! spec from anywhere else gets checked as well.  Messages are the same.

use crate::spec::{Source, Spec};
use std::collections::BTreeMap;

/// The spec's checks in the order checks.nix makes them, the first failing
/// one's message.
pub fn spec(spec: &Spec) -> Result<(), String> {
    target_path(&spec.target.path)?;
    for name in spec.source.keys() {
        source_name(name)?;
    }
    inputs(&spec.source)
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
    // a source if drawing goes round in circles.
    fn visit<'a>(
        name: &'a str,
        drawn_from: &'a BTreeMap<&str, Vec<String>>,
        done: &mut Vec<&'a str>,
        path: &mut Vec<&'a str>,
    ) -> Result<(), String> {
        if let Some(i) = path.iter().position(|p| *p == name) {
            return Err(format!(
                "krops: sources draw inputs from each other: {}",
                path[i..].join(" ")
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
}
