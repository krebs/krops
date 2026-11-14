//! populate [OPTION]... SOURCES [TARGET]: delivers the sources in the JSON
//! file SOURCES, or standard input for -, to the target directory TARGET.
//! See README.md.

mod check;
mod cli;
mod flake;
mod flake_input;
mod populate;
mod rsync;
mod run;
mod sh;
mod spec;

use std::io::Read;
use std::process::ExitCode;

/// Exit status when the command line is wrong, or the sources can't be read
/// or aren't sources.
const USAGE: u8 = 2;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let options = match cli::parse(&args) {
        Ok(cli::Command::Help) => {
            print!("{}", cli::USAGE);
            return ExitCode::SUCCESS;
        }
        Ok(cli::Command::Version) => {
            println!("populate {}", env!("CARGO_PKG_VERSION"));
            return ExitCode::SUCCESS;
        }
        Ok(cli::Command::Populate(options)) => options,
        Err(message) => {
            eprintln!("populate: {message}");
            eprint!(
                "{}",
                cli::USAGE
                    .lines()
                    .next()
                    .map(|l| format!("{l}\n"))
                    .unwrap_or_default()
            );
            return ExitCode::from(USAGE);
        }
    };
    let path = &options.sources;
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
    let source: spec::Sources = match serde_json::from_str(&text) {
        Ok(source) => source,
        Err(e) => {
            eprintln!("populate: {path} doesn't contain sources: {e}");
            return ExitCode::from(USAGE);
        }
    };
    let origin = run::Origin::from_env();
    let target = options
        .target
        .complete(&origin, options.sudo, options.ssh_args);
    let local = options.local.unwrap_or_else(|| origin.is_local(&target));
    let spec = spec::Spec {
        backup: options.backup,
        force: options.force,
        prune: options.prune,
        source,
        target,
    };
    if let Err(message) = check::spec(&spec) {
        eprintln!("{message}");
        return ExitCode::FAILURE;
    }
    run::trap_signals();
    let context = match run::Context::new(spec.target.clone(), local) {
        Ok(context) => context,
        Err(failure) => return exit(failure),
    };
    let result = populate::populate(&context, &spec);
    run::ignore_signals();
    context.clean_up();
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(failure) => exit(failure),
    }
}

/// Says why populate fails, unless a command did, and returns the exit
/// status for that.
fn exit(failure: run::Failure) -> ExitCode {
    match failure {
        run::Failure::Message(message) => {
            eprintln!("{message}");
            ExitCode::FAILURE
        }
        run::Failure::Command(status) => ExitCode::from(status),
        run::Failure::Signal(signal) => ExitCode::from(128 + signal as u8),
    }
}
