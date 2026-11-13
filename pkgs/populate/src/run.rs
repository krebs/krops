//! Running commands: on the deploying machine, and on the target, directly
//! or over ssh, sharing one master connection.

use crate::spec::Target;
use std::fmt;
use std::fs;
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitStatus, Stdio};
use std::sync::atomic::{AtomicI32, Ordering};

/// Why populate stops before delivering everything.
#[derive(Debug)]
pub enum Failure {
    /// A message to print.
    Message(String),
    /// A command failed, after printing why, with its exit status, which
    /// populate exits with: the shell implementation, running under set -e,
    /// does, so e.g. 255 from ssh still tells a connection failure.
    Command(u8),
    /// A signal arrived: SIGHUP, SIGINT, or SIGTERM.
    Signal(i32),
}

impl fmt::Display for Failure {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        match self {
            Failure::Message(message) => f.write_str(message),
            Failure::Command(status) => write!(f, "a command failed with status {status}"),
            Failure::Signal(signal) => write!(f, "got signal {signal}"),
        }
    }
}

pub type Result<T> = std::result::Result<T, Failure>;

/// The signal that arrived last, or 0.
static SIGNAL: AtomicI32 = AtomicI32::new(0);

extern "C" fn record_signal(signal: libc::c_int) {
    SIGNAL.store(signal, Ordering::SeqCst);
}

/// Makes SIGHUP, SIGINT, and SIGTERM get recorded instead of ending
/// populate, so it can clean up.  A signal to the process group, like the
/// one of an interrupt key, ends the command populate waits for, too, after
/// which populate stops.  A signal to populate alone takes effect once that
/// command ends.
pub fn trap_signals() {
    for signal in [libc::SIGHUP, libc::SIGINT, libc::SIGTERM] {
        // SAFETY: the handler only stores into an atomic.
        unsafe {
            let mut action: libc::sigaction = std::mem::zeroed();
            action.sa_sigaction = record_signal as extern "C" fn(libc::c_int) as usize;
            action.sa_flags = libc::SA_RESTART;
            libc::sigemptyset(&mut action.sa_mask);
            libc::sigaction(signal, &action, std::ptr::null_mut());
        }
    }
}

/// Ignores further signals, so they don't end cleaning up halfway.
pub fn ignore_signals() {
    for signal in [libc::SIGHUP, libc::SIGINT, libc::SIGTERM] {
        // SAFETY: setting a disposition has no other effect.
        unsafe {
            libc::signal(signal, libc::SIG_IGN);
        }
    }
}

/// Fails if a signal arrived.
pub fn check_signal() -> Result<()> {
    match SIGNAL.load(Ordering::SeqCst) {
        0 => Ok(()),
        signal => Err(Failure::Signal(signal)),
    }
}

/// Quotes a word for POSIX shells.
pub fn quote(word: &str) -> String {
    let safe = |c: char| c.is_ascii_alphanumeric() || "-+./:=_@%,".contains(c);
    if !word.is_empty() && word.chars().all(safe) {
        word.to_string()
    } else {
        format!("'{}'", word.replace('\'', r"'\''"))
    }
}

/// Where populate delivers to, and how it gets there.
pub struct Context {
    pub target: Target,
    /// Whether the target is the machine populate runs on, as the user
    /// running it, so commands run directly instead of over ssh.
    pub local: bool,
    /// Populate's private temporary directory, which is $TMPDIR for the
    /// commands it runs.
    pub tmpdir: PathBuf,
    /// The ssh command, with the options for the target and for sharing a
    /// master connection, as a script in tmpdir, for rsync's -e as well.
    pub ssh: PathBuf,
    /// The ssh command for Nix's ssh:// store.  Without the control socket,
    /// because Nix waits for its LocalCommand, which may not run over a
    /// multiplexed connection.
    pub ssh_nix: PathBuf,
    /// What nix flake metadata prints for flakes, by reference, so it's
    /// obtained only once, even if several sources use the same flake.
    metadata: std::cell::RefCell<std::collections::BTreeMap<String, serde_json::Value>>,
}

impl Context {
    /// Creates the temporary directory, and the ssh script in it.
    pub fn new(target: Target, local: Option<bool>) -> Result<Context> {
        let local = local.unwrap_or_else(|| is_local(&target));
        let output = Command::new("mktemp")
            .args(["-dt", "populate.XXXXXXXX"])
            .stderr(Stdio::inherit())
            .output()
            .map_err(|e| Failure::Message(format!("error: can't run mktemp: {e}")))?;
        if !output.status.success() {
            return Err(failed(output.status));
        }
        let tmpdir = PathBuf::from(String::from_utf8_lossy(&output.stdout).trim_end());
        // Shared with the commands populate runs.
        std::env::set_var("TMPDIR", &tmpdir);
        let ssh = tmpdir.join("ssh");
        let ssh_nix = tmpdir.join("ssh-nix");
        let context = Context {
            target,
            local,
            tmpdir,
            ssh,
            ssh_nix,
            metadata: Default::default(),
        };
        context.write_ssh(&context.ssh, &context.ssh_options(true))?;
        context.write_ssh(&context.ssh_nix, &context.ssh_options(false))?;
        Ok(context)
    }

    /// Writes a script running ssh with options.  ssh is the one in PATH
    /// now, so the script can be ssh in PATH itself, as for nix copy.
    fn write_ssh(&self, path: &Path, options: &[String]) -> Result<()> {
        let ssh = which("ssh").unwrap_or_else(|| PathBuf::from("ssh"));
        let mut script = format!("#!/bin/sh\nexec {}", quote(&ssh.to_string_lossy()));
        for word in options {
            script.push(' ');
            script.push_str(&quote(word));
        }
        script.push_str(" \"$@\"\n");
        let write = || -> std::io::Result<()> {
            let mut file = fs::File::create(path)?;
            file.write_all(script.as_bytes())?;
            fs::set_permissions(path, fs::Permissions::from_mode(0o700))
        };
        write().map_err(|e| Failure::Message(format!("error: can't write {}: {e}", path.display())))
    }

    fn ssh_options(&self, shared: bool) -> Vec<String> {
        let mut options = Vec::new();
        if let Some(user) = &self.target.user {
            options.extend(["-l".to_string(), user.clone()]);
        }
        if let Some(port) = &self.target.port {
            options.extend(["-p".to_string(), port.clone()]);
        }
        if shared {
            let control_path = format!("ControlPath={}/ssh-%r@%h:%p.sock", self.tmpdir.display());
            for option in ["ControlMaster=auto", &control_path, "ControlPersist=1h"] {
                options.extend(["-o".to_string(), option.to_string()]);
            }
            options.push("-T".to_string());
        }
        options.extend(self.target.extra_options.iter().cloned());
        options
    }

    /// The path on the target, as populate names it in what it prints:
    /// prefixed by the host if the target isn't local, and by the user as
    /// well if that isn't root.
    pub fn name(&self, path: &str) -> String {
        if self.local {
            return path.to_string();
        }
        let user = match self.target.user.as_deref() {
            None | Some("") | Some("root") => String::new(),
            Some(user) => format!("{user}@"),
        };
        format!("{user}{}:{path}", self.target.host)
    }

    /// The path on the target, as rsync names it.
    pub fn rsync_destination(&self, path: &str) -> String {
        if self.local {
            return path.to_string();
        }
        let user = match self.target.user.as_deref() {
            None | Some("") => String::new(),
            Some(user) => format!("{user}@"),
        };
        format!("{user}{}:{path}", self.target.host)
    }

    /// A command running the shell code script on the target, with args as
    /// its positional parameters.  Over ssh, the remote shell gets it as
    /// one quoted command, run via sudo if the target says so.
    pub fn shell(&self, script: &str, args: &[&str]) -> Command {
        let script = format!("set -efu\n{script}");
        if self.local {
            let mut command = Command::new("sh");
            command.arg("-c").arg(script).arg("sh").args(args);
            command
        } else {
            let mut words = vec![
                if self.target.sudo {
                    "sudo sh -c"
                } else {
                    "sh -c"
                }
                .to_string(),
                quote(&script),
                "sh".to_string(),
            ];
            words.extend(args.iter().map(|arg| quote(arg)));
            let mut command = Command::new(&self.ssh);
            command.arg(&self.target.host).arg(words.join(" "));
            command
        }
    }

    /// Runs shell code on the target, with its output going where
    /// populate's errors go.
    pub fn run(&self, script: &str, args: &[&str]) -> Result<()> {
        let mut command = self.shell(script, args);
        command.stdout(stderr());
        status(&mut command)
    }

    /// What nix flake metadata prints for the flake url, as get gets it,
    /// once.
    pub fn flake_metadata(
        &self,
        url: &str,
        get: impl FnOnce() -> Result<String>,
    ) -> Result<serde_json::Value> {
        if let Some(metadata) = self.metadata.borrow().get(url) {
            return Ok(metadata.clone());
        }
        let metadata: serde_json::Value = serde_json::from_str(&get()?).map_err(|e| {
            Failure::Message(format!("error: can't read flake metadata of {url}: {e}"))
        })?;
        self.metadata
            .borrow_mut()
            .insert(url.to_string(), metadata.clone());
        Ok(metadata)
    }

    /// Runs shell code on the target, returning its output.
    pub fn output(&self, script: &str, args: &[&str]) -> Result<String> {
        output(&mut self.shell(script, args))
    }

    /// Stops the ssh master, if any command started one, and removes the
    /// temporary directory.
    pub fn clean_up(&self) {
        if !self.local {
            let check = Command::new(&self.ssh)
                .args(["-q", "-O", "check", &self.target.host])
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status();
            if matches!(check, Ok(status) if status.success()) {
                let _ = Command::new(&self.ssh)
                    .args(["-q", "-O", "stop", &self.target.host])
                    .stdin(Stdio::null())
                    .status();
            }
        }
        let _ = Command::new("rm").arg("-R").arg(&self.tmpdir).status();
    }
}

/// A command running shell code on the deploying machine, in dir, with
/// args as its positional parameters.
pub fn local_shell(script: &str, args: &[&str], dir: &Path) -> Command {
    let mut command = Command::new("sh");
    command
        .arg("-c")
        .arg(format!("set -efu\n{script}"))
        .arg("sh")
        .args(args)
        .current_dir(dir);
    command
}

/// The program named name in PATH.
fn which(name: &str) -> Option<PathBuf> {
    let path = std::env::var_os("PATH")?;
    std::env::split_paths(&path)
        .map(|dir| dir.join(name))
        .find(|file| {
            fs::metadata(file).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
        })
}

/// Where populate's errors go, for commands whose output goes there too.
pub fn stderr() -> Stdio {
    use std::os::fd::AsFd;
    match std::io::stderr().as_fd().try_clone_to_owned() {
        Ok(fd) => Stdio::from(fd),
        Err(_) => Stdio::inherit(),
    }
}

fn spawn_error(command: &Command, e: std::io::Error) -> Failure {
    Failure::Message(format!(
        "error: can't run {}: {e}",
        command.get_program().to_string_lossy()
    ))
}

/// The failure of a command that exited with status, or, like in a shell,
/// with 128 plus the signal that ended it.
fn failed(status: ExitStatus) -> Failure {
    use std::os::unix::process::ExitStatusExt;
    let code = match (status.code(), status.signal()) {
        (Some(code), _) => code,
        (None, Some(signal)) => 128 + signal,
        (None, None) => 1,
    };
    Failure::Command(u8::try_from(code).ok().filter(|c| *c != 0).unwrap_or(1))
}

/// Runs a command, failing if it fails, or if a signal arrived meanwhile.
pub fn status(command: &mut Command) -> Result<()> {
    let result: std::io::Result<ExitStatus> = command.status();
    check_signal()?;
    match result {
        Ok(status) if status.success() => Ok(()),
        Ok(status) => Err(failed(status)),
        Err(e) => Err(spawn_error(command, e)),
    }
}

/// Runs a command, returning its output, failing like status.
pub fn output(command: &mut Command) -> Result<String> {
    command.stderr(Stdio::inherit());
    let result = command.output();
    check_signal()?;
    match result {
        Ok(output) if output.status.success() => {
            Ok(String::from_utf8_lossy(&output.stdout).into_owned())
        }
        Ok(output) => Err(failed(output.status)),
        Err(e) => Err(spawn_error(command, e)),
    }
}

/// Whether the target is the machine populate runs on, as the user running
/// it: its user is that user, and its host is localhost or the machine's
/// name, like krops' lib's isLocalTarget decides during evaluation.
fn is_local(target: &Target) -> bool {
    let user = std::env::var("LOGNAME").ok();
    let host = std::env::var("HOSTNAME").ok().or_else(host_name);
    target.user == user && (target.host == "localhost" || Some(&target.host) == host.as_ref())
}

/// The machine's name, from /etc/hostname, as krops' lib reads it.
fn host_name() -> Option<String> {
    let text = fs::read_to_string("/etc/hostname").ok()?;
    let label = |line: &&str| {
        !line.is_empty()
            && line.len() <= 63
            && line.chars().all(|c| c.is_ascii_alphanumeric() || c == '-')
            && !line.starts_with('-')
            && !line.ends_with('-')
    };
    let names: Vec<&str> = text.lines().filter(label).collect();
    match names.as_slice() {
        [name] => Some(name.to_string()),
        _ => None,
    }
}

/// Tells whether path is a path in the store itself, not one below it.
pub fn is_store_path(path: &str) -> bool {
    Path::new(path).parent() == Some(Path::new("/nix/store")) && path.len() > "/nix/store/".len()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quoting() {
        assert_eq!(quote("abc/d.e"), "abc/d.e");
        assert_eq!(quote(""), "''");
        assert_eq!(quote("a b"), "'a b'");
        assert_eq!(quote("it's"), r"'it'\''s'");
    }

    #[test]
    fn store_paths() {
        assert!(is_store_path("/nix/store/abc-x"));
        assert!(!is_store_path("/nix/store/abc-x/y"));
        assert!(!is_store_path("/nix/store"));
        assert!(!is_store_path("/etc"));
    }
}
