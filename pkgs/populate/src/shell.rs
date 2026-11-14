//! populate shell: runs shell code on a target, reached like populate
//! reaches it.

use crate::cli::ShellOptions;
use crate::run::{self, Origin};
use std::os::unix::process::CommandExt;
use std::process::{Command, ExitCode};

/// Runs the script as the options say, replacing populate, so the script's
/// exit status, terminal, and signals are populate's.  Returns only if
/// that fails.
pub fn shell(options: ShellOptions) -> ExitCode {
    let origin = Origin::from_env();
    let target = options
        .target
        .complete(&origin, options.sudo, options.ssh_args);
    let local = options.local.unwrap_or_else(|| origin.is_local(&target));
    if options.local_only && !local {
        let user = target
            .user
            .as_deref()
            .map(|user| format!("{user}@"))
            .unwrap_or_default();
        eprintln!(
            "populate: shell: {user}{} is not the machine populate runs on",
            target.host
        );
        return ExitCode::FAILURE;
    }
    let mut words: Vec<String> = Vec::new();
    if target.sudo {
        words.push("sudo".to_string());
    }
    words.extend([
        "/bin/sh".to_string(),
        "-c".to_string(),
        options.script,
        "sh".to_string(),
        if local { "local" } else { "remote" }.to_string(),
    ]);
    let mut command = if local {
        let mut command = Command::new(&words[0]);
        command.args(&words[1..]);
        command
    } else {
        let mut command = Command::new("ssh");
        if let Some(user) = &target.user {
            command.args(["-l", user]);
        }
        if let Some(port) = &target.port {
            command.args(["-p", port]);
        }
        command
            .arg(if options.tty { "-t" } else { "-T" })
            .args(&target.extra_options)
            .arg(&target.host)
            .arg(
                words
                    .iter()
                    .map(|word| run::quote(word))
                    .collect::<Vec<_>>()
                    .join(" "),
            );
        command
    };
    let error = command.exec();
    eprintln!(
        "populate: shell: can't run {}: {error}",
        command.get_program().to_string_lossy()
    );
    ExitCode::from(127)
}
