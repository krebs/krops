//! The spec: populate's arguments as JSON, as docs/design.md describes them.

// Delivering sources isn't implemented yet, so most of the spec is unused.
#![allow(dead_code)]

use serde::Deserialize;
use serde_json::{Map, Value};
use std::collections::BTreeMap;

/// The version of the spec this populate reads.
pub const VERSION: u64 = 1;

/// The source types populate knows.
pub const SOURCE_TYPES: &[&str] = &[
    "derivation",
    "file",
    "flake",
    "flake-input",
    "git",
    "pass",
    "passage",
    "pipe",
    "symlink",
];

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Spec {
    pub version: u64,
    #[serde(default)]
    pub backup: bool,
    #[serde(default)]
    pub force: bool,
    #[serde(default)]
    pub prune: bool,
    pub source: BTreeMap<String, Source>,
    pub target: Target,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct Target {
    #[serde(default)]
    pub user: Option<String>,
    pub host: String,
    #[serde(default)]
    pub port: Option<String>,
    pub path: String,
    #[serde(default)]
    pub sudo: bool,
    #[serde(default)]
    pub extra_options: Vec<String>,
}

/// A source: its type, and the settings of that type, under the type's name.
#[derive(Debug)]
pub struct Source {
    pub kind: String,
    pub settings: Map<String, Value>,
}

impl<'de> Deserialize<'de> for Source {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        use serde::de::Error;
        let mut object = Map::deserialize(deserializer)?;
        let kind = match object.remove("type") {
            Some(Value::String(kind)) => kind,
            Some(_) => return Err(D::Error::custom("type must be a string")),
            None => return Err(D::Error::missing_field("type")),
        };
        if !SOURCE_TYPES.contains(&kind.as_str()) {
            return Err(D::Error::custom(format!("unknown source type {kind:?}")));
        }
        let settings = match object.remove(&kind) {
            Some(Value::Object(settings)) => settings,
            Some(_) => return Err(D::Error::custom(format!("{kind} must be an object"))),
            None => return Err(D::Error::missing_field("settings named after the type")),
        };
        if let Some(other) = object.keys().next() {
            return Err(D::Error::custom(format!(
                "unknown field {other:?} of a {kind} source"
            )));
        }
        Ok(Source { kind, settings })
    }
}

/// An input drawn from another source: the path of input names of the flake
/// in the source drawing it, and the name of the source it's drawn from.
#[derive(Debug, PartialEq)]
pub struct Follows {
    pub path: Vec<String>,
    pub source: String,
}

impl Source {
    /// The inputs this source draws from other sources, like krops' lib's
    /// flakeFollows.
    pub fn follows(&self) -> Vec<Follows> {
        fn walk(prefix: &[String], inputs: &Map<String, Value>, out: &mut Vec<Follows>) {
            for (name, input) in inputs {
                let mut path = prefix.to_vec();
                path.push(name.clone());
                if let Some(Value::String(source)) = input.get("follows") {
                    out.push(Follows {
                        path: path.clone(),
                        source: source.clone(),
                    });
                }
                if let Some(Value::Object(inputs)) = input.get("inputs") {
                    walk(&path, inputs, out);
                }
            }
        }
        let mut out = Vec::new();
        if let Some(Value::Object(inputs)) = self.settings.get("inputs") {
            walk(&[], inputs, &mut out);
        }
        out
    }
}
