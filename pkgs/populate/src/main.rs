//! populate SPEC: delivers sources to a target directory, as the spec, a
//! JSON file or - for standard input, says.  See docs/design.md.

mod check;
mod spec;

use std::io::Read;
use std::process::ExitCode;

/// Exit status when the spec can't be read, isn't JSON, or isn't a spec.
const USAGE: u8 = 2;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let [path] = args.as_slice() else {
        eprintln!("usage: populate SPEC");
        return ExitCode::from(USAGE);
    };
    let text = if path == "-" {
        let mut text = String::new();
        std::io::stdin().read_to_string(&mut text).map(|_| text)
    } else {
        std::fs::read_to_string(path)
    };
    let text = match text {
        Ok(text) => text,
        Err(e) => {
            eprintln!("populate: can't read {path}: {e}");
            return ExitCode::from(USAGE);
        }
    };
    let version = serde_json::from_str::<serde_json::Value>(&text)
        .ok()
        .and_then(|value| value.get("version").and_then(|v| v.as_u64()));
    if let Some(version) = version.filter(|v| *v != spec::VERSION) {
        eprintln!(
            "populate: {path} is a spec of version {version}, this populate reads version {}",
            spec::VERSION
        );
        return ExitCode::from(USAGE);
    }
    let spec: spec::Spec = match serde_json::from_str(&text) {
        Ok(spec) => spec,
        Err(e) => {
            eprintln!("populate: {path} isn't a spec: {e}");
            return ExitCode::from(USAGE);
        }
    };
    if let Err(message) = check::spec(&spec) {
        eprintln!("{message}");
        return ExitCode::FAILURE;
    }
    eprintln!("populate: delivering sources isn't implemented yet");
    ExitCode::FAILURE
}
