//! What populate delivers where: the sources, as JSON, and the target, as
//! the command line gives it.  See README.md.

use crate::run::Origin;
use serde::Deserialize;
use serde_json::{Map, Value};
use std::collections::BTreeMap;

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

/// The sources, by name, as a JSON object.
pub type Sources = BTreeMap<String, Source>;

#[derive(Debug)]
pub struct Spec {
    pub backup: bool,
    pub force: bool,
    pub prune: bool,
    pub source: Sources,
    pub target: Target,
}

#[derive(Clone, Debug)]
pub struct Target {
    pub user: Option<String>,
    pub host: String,
    pub port: Option<String>,
    pub path: String,
    pub sudo: bool,
    pub extra_options: Vec<String>,
}

/// The parts of a target that [USER@][HOST][:PORT][PATH] gives, like krops'
/// lib's mkTarget parses it.
#[derive(Debug, Default, PartialEq)]
pub struct TargetParts {
    pub user: Option<String>,
    pub host: Option<String>,
    pub port: Option<String>,
    pub path: Option<String>,
}

impl TargetParts {
    /// Parses text like the regular expression
    /// (([^@]*)@)?(([^:/]+))?(:([^/]+))?(/.*)? of mkTarget: the user up to
    /// the first @, the host up to a : or a /, the port up to a /, and the
    /// path from there.
    pub fn parse(text: &str) -> Result<TargetParts, String> {
        let invalid = || format!("invalid target {text:?}: not [USER@][HOST][:PORT][PATH]");
        let (user, rest) = match text.split_once('@') {
            Some((user, rest)) => (Some(user.to_string()), rest),
            None => (None, text),
        };
        let end = rest.find([':', '/']).unwrap_or(rest.len());
        let (host, rest) = rest.split_at(end);
        let (port, path) = match rest.strip_prefix(':') {
            Some(rest) => {
                let end = rest.find('/').unwrap_or(rest.len());
                let (port, path) = rest.split_at(end);
                if port.is_empty() {
                    return Err(invalid());
                }
                (Some(port.to_string()), path)
            }
            None => (None, rest),
        };
        Ok(TargetParts {
            user,
            host: Some(host.to_string()).filter(|h| !h.is_empty()),
            port,
            path: Some(path.to_string()).filter(|p| !p.is_empty()),
        })
    }

    /// The target, with what's missing as mkTarget defaults it: the user
    /// running populate, the machine's name, and /var/src.  An empty user
    /// means ssh's default.
    pub fn complete(self, origin: &Origin, sudo: bool, extra_options: Vec<String>) -> Target {
        Target {
            user: match self.user {
                Some(user) => Some(user).filter(|u| !u.is_empty()),
                None => origin.user.clone(),
            },
            host: self.host.unwrap_or_else(|| origin.host.clone()),
            port: self.port,
            path: self.path.unwrap_or_else(|| "/var/src".to_string()),
            sudo,
            extra_options,
        }
    }
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
    /// The inputs this source draws from other sources, like flakeFollows
    /// of populate's Nix library.
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

#[cfg(test)]
mod tests {
    use super::*;

    fn parts(text: &str) -> TargetParts {
        TargetParts::parse(text).unwrap()
    }

    fn some(s: &str) -> Option<String> {
        Some(s.to_string())
    }

    #[test]
    fn target_syntax() {
        assert_eq!(parts(""), TargetParts::default());
        assert_eq!(
            parts("/srv/src"),
            TargetParts {
                path: some("/srv/src"),
                ..Default::default()
            }
        );
        assert_eq!(
            parts("host"),
            TargetParts {
                host: some("host"),
                ..Default::default()
            }
        );
        assert_eq!(
            parts("tv@host:22/x"),
            TargetParts {
                user: some("tv"),
                host: some("host"),
                port: some("22"),
                path: some("/x")
            }
        );
        // The user ends at the first @, the port at the first /.
        assert_eq!(parts("a@b@c").host, some("b@c"));
        assert_eq!(parts("h:p:q/r").port, some("p:q"));
        assert_eq!(parts(":22").host, None);
        assert!(TargetParts::parse("host:").is_err());
        assert!(TargetParts::parse("host:/x").is_err());
    }

    #[test]
    fn target_defaults() {
        let origin = Origin {
            user: some("tv"),
            host: "ni".to_string(),
        };
        let target = parts("").complete(&origin, false, vec![]);
        assert_eq!(
            (
                target.user.as_deref(),
                target.host.as_str(),
                target.path.as_str()
            ),
            (Some("tv"), "ni", "/var/src")
        );
        // An empty user means ssh's default.
        assert_eq!(parts("@h").complete(&origin, true, vec![]).user, None);
    }
}
