//! Running commands: on the deploying machine, and on the target, directly
//! or over ssh, sharing one master connection.

use crate::spec::Target;
use std::fmt;
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitStatus, Stdio};
use std::sync::atomic::{AtomicI32, Ordering};

/// The shell running shell code, on the deploying machine and on the
/// target, by its path, so neither needs a shell in PATH.
pub const SH: &str = "/bin/sh";

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
    /// The paths of Git work trees on the target that git_problems found
    /// nothing wrong with during this run, so finding that out, which
    /// takes looking through all of the work tree, happens only once.
    git_checked: std::cell::RefCell<std::collections::BTreeSet<String>>,
    /// The journal on the target, once populate holds the lock, see lock.
    journal: std::cell::RefCell<Option<String>>,
    /// This run's entries of the journal, and how many of them are in the
    /// journal on the target already.
    entries: std::cell::RefCell<(Vec<serde_json::Value>, usize)>,
    /// The command holding the lock on the target directory, see lock, and
    /// the lock file's name in messages.
    lock: std::cell::RefCell<Option<(Child, String)>>,
}

impl Context {
    /// Creates the temporary directory, and the ssh script in it.
    pub fn new(target: Target, local: bool) -> Result<Context> {
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
            git_checked: Default::default(),
            journal: Default::default(),
            entries: Default::default(),
            lock: Default::default(),
        };
        context.write_ssh(&context.ssh, &context.ssh_options(true))?;
        context.write_ssh(&context.ssh_nix, &context.ssh_options(false))?;
        Ok(context)
    }

    /// Writes a script running ssh with options.  ssh is the one in PATH
    /// now, so the script can be ssh in PATH itself, as for nix copy.
    fn write_ssh(&self, path: &Path, options: &[String]) -> Result<()> {
        let ssh = which("ssh").unwrap_or_else(|| PathBuf::from("ssh"));
        let mut script = format!("#!{SH}\nexec {}", quote(&ssh.to_string_lossy()));
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
            // The keepalives end the connection, and with it the command
            // holding the lock on the target, about a minute after the
            // target stops answering, e.g. when the network fails, instead
            // of after TCP gives up, which may take hours.
            for option in [
                "ControlMaster=auto",
                &control_path,
                "ControlPersist=1h",
                "ServerAliveInterval=15",
                "ServerAliveCountMax=4",
            ] {
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
    /// The entries of the journal not in the journal on the target yet get
    /// there first, so they precede what the command changes.  Fails if
    /// populate lost the lock on the target directory, see check_lock.
    pub fn shell(&self, script: &str, args: &[&str]) -> Result<Command> {
        self.check_lock()?;
        let mut lines = Vec::new();
        if let Some(journal) = &*self.journal.borrow() {
            let (entries, flushed) = &mut *self.entries.borrow_mut();
            if *flushed < entries.len() {
                lines.push(journal.clone());
                lines.push((entries.len() - *flushed).to_string());
                lines.extend(entries[*flushed..].iter().map(|entry| entry.to_string()));
                *flushed = entries.len();
            }
        }
        let script = if lines.is_empty() {
            format!("set -efu\n{script}")
        } else {
            format!("set -efu\n{}{script}", crate::sh::JOURNAL)
        };
        let args: Vec<&str> = lines
            .iter()
            .map(String::as_str)
            .chain(args.iter().copied())
            .collect();
        let args = args.as_slice();
        if self.local {
            let mut command = Command::new(SH);
            command.arg("-c").arg(script).arg("sh").args(args);
            Ok(command)
        } else {
            let mut words = vec![
                if self.target.sudo {
                    format!("sudo {SH} -c")
                } else {
                    format!("{SH} -c")
                },
                quote(&script),
                "sh".to_string(),
            ];
            words.extend(args.iter().map(|arg| quote(arg)));
            let mut command = Command::new(&self.ssh);
            command.arg(&self.target.host).arg(words.join(" "));
            Ok(command)
        }
    }

    /// Takes the lock on the target directory, whose sentinel is sentinel,
    /// adding entry to the journal, which entries go to from now on, until
    /// unlock.  Returns the lines that runs that didn't finish left in the
    /// journal, and the lines of the last run's record.
    pub fn lock(
        &self,
        sentinel: &str,
        entry: serde_json::Value,
    ) -> Result<(Vec<String>, Vec<String>)> {
        let mut command = self.shell(
            crate::sh::LOCK,
            &[sentinel, &self.name(sentinel), &entry.to_string()],
        )?;
        command
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit());
        let mut child = command.spawn().map_err(|e| spawn_error(&command, e))?;
        let stdout = child.stdout.take().expect("piped");
        let mut journal = Vec::new();
        let mut record = None;
        let mut locked = false;
        for line in BufReader::new(stdout).lines() {
            let line = line.map_err(|e| {
                Failure::Message(format!(
                    "error: can't read from the command taking the lock: {e}"
                ))
            })?;
            if line == "locked" {
                locked = true;
                break;
            }
            match &mut record {
                None if line == "record" => record = Some(Vec::new()),
                None => journal.push(line),
                Some(record) => record.push(line),
            }
        }
        if !locked {
            drop(child.stdin.take());
            let status = child.wait().map_err(|e| spawn_error(&command, e))?;
            check_signal()?;
            return Err(if status.success() {
                Failure::Message("error: can't take the lock on the target directory".to_string())
            } else {
                failed(status)
            });
        }
        *self.lock.borrow_mut() = Some((child, self.name(&format!("{sentinel}/lock"))));
        check_signal()?;
        *self.journal.borrow_mut() = Some(format!("{sentinel}/journal"));
        self.entries.borrow_mut().0.push(entry);
        self.entries.borrow_mut().1 = 1;
        Ok((journal, record.unwrap_or_default()))
    }

    /// Fails if the command holding the lock ended, e.g. killed on the
    /// target, or with the ssh connection, which releases the lock, so a
    /// run that isn't locked throughout doesn't get recorded.
    pub fn check_lock(&self) -> Result<()> {
        if let Some((child, name)) = &mut *self.lock.borrow_mut() {
            if !matches!(child.try_wait(), Ok(None)) {
                return Err(Failure::Message(format!(
                    "error: populate lost the lock on {name}"
                )));
            }
        }
        Ok(())
    }

    /// Releases the lock: the input of the command holding it ending ends
    /// the command.
    pub fn unlock(&self) {
        if let Some((mut child, _)) = self.lock.borrow_mut().take() {
            drop(child.stdin.take());
            let _ = child.wait();
        }
    }

    /// Adds entry to the journal, see the record module.
    pub fn note(&self, entry: serde_json::Value) {
        if self.journal.borrow().is_some() {
            self.entries.borrow_mut().0.push(entry);
        }
    }

    /// This run's entries of the journal.
    pub fn entries(&self) -> Vec<serde_json::Value> {
        self.entries.borrow().0.clone()
    }

    /// Runs shell code on the target, with its output going where
    /// populate's errors go.
    pub fn run(&self, script: &str, args: &[&str]) -> Result<()> {
        let mut command = self.shell(script, args)?;
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

    /// Notes that git_problems found nothing wrong with the Git work tree
    /// at path on the target.
    pub fn git_checked(&self, path: &str) {
        self.git_checked.borrow_mut().insert(path.to_string());
    }

    /// Whether git_problems found nothing wrong with the Git work tree at
    /// path on the target during this run.
    pub fn is_git_checked(&self, path: &str) -> bool {
        self.git_checked.borrow().contains(path)
    }

    /// Runs shell code on the target, returning its output.
    pub fn output(&self, script: &str, args: &[&str]) -> Result<String> {
        output(&mut self.shell(script, args)?)
    }

    /// Releases the lock, stops the ssh master, if any command started one,
    /// and removes the temporary directory.
    pub fn clean_up(&self) {
        self.unlock();
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
    let mut command = Command::new(SH);
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

/// Runs a command, passing each line of its output to each, failing like
/// status.
pub fn lines(command: &mut Command, mut each: impl FnMut(&str)) -> Result<()> {
    command.stdout(Stdio::piped());
    let mut child = command.spawn().map_err(|e| spawn_error(command, e))?;
    let stdout = child.stdout.take().expect("piped");
    for line in BufReader::new(stdout).lines() {
        match line {
            Ok(line) => each(&line),
            Err(_) => break,
        }
    }
    let result = child.wait();
    check_signal()?;
    match result {
        Ok(status) if status.success() => Ok(()),
        Ok(status) => Err(failed(status)),
        Err(e) => Err(spawn_error(command, e)),
    }
}

/// The user running populate, and the name of the machine it runs on, like
/// krops' lib's mkTarget and isLocalTarget take them.
#[derive(Clone, Debug)]
pub struct Origin {
    pub user: Option<String>,
    pub host: String,
}

impl Origin {
    /// From LOGNAME, HOSTNAME, and /etc/hostname.
    pub fn from_env() -> Origin {
        let etc_hostname = fs::read_to_string("/etc/hostname").ok();
        Origin::from(
            std::env::var("LOGNAME").ok().as_deref(),
            std::env::var("HOSTNAME").ok().as_deref(),
            etc_hostname.as_deref(),
        )
    }

    /// Given LOGNAME, HOSTNAME, and the contents of /etc/hostname.  Like
    /// lib.maybeEnv, an empty variable counts as unset.  The user is
    /// LOGNAME, if set, and the machine's name is HOSTNAME, or else the only
    /// line of /etc/hostname that is a label, or else localhost.
    pub fn from(
        logname: Option<&str>,
        hostname: Option<&str>,
        etc_hostname: Option<&str>,
    ) -> Origin {
        Origin {
            user: logname.filter(|v| !v.is_empty()).map(str::to_string),
            host: hostname
                .filter(|v| !v.is_empty())
                .map(str::to_string)
                .or_else(|| etc_hostname.and_then(host_name))
                .unwrap_or_else(|| "localhost".to_string()),
        }
    }

    /// Whether target is the machine populate runs on, as the user running
    /// it: its user is that user, and its host is the machine's name or
    /// localhost.
    pub fn is_local(&self, target: &Target) -> bool {
        target.user == self.user && (target.host == "localhost" || target.host == self.host)
    }
}

/// The machine's name in the contents of /etc/hostname: its only line that
/// is a label, as krops' lib reads it.
fn host_name(text: &str) -> Option<String> {
    let label = |line: &&str| {
        !line.is_empty()
            && line.chars().all(|c| c.is_ascii_alphanumeric() || c == '-')
            && !line.starts_with('-')
            && !line.ends_with('-')
    };
    let names: Vec<&str> = text.split('\n').filter(label).collect();
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

    fn target(user: Option<&str>, host: &str) -> Target {
        Target {
            user: user.map(str::to_string),
            host: host.to_string(),
            port: None,
            path: "/var/src".to_string(),
            sudo: false,
            extra_options: vec![],
        }
    }

    #[test]
    fn local_targets() {
        let local =
            |t: &Target, logname, hostname, etc| Origin::from(logname, hostname, etc).is_local(t);
        // An empty LOGNAME counts as unset, i.e. the user null.
        assert!(local(&target(None, "localhost"), Some(""), None, None));
        assert!(!local(&target(None, "localhost"), Some("tv"), None, None));
        assert!(local(
            &target(Some("tv"), "localhost"),
            Some("tv"),
            None,
            None
        ));
        // An empty HOSTNAME counts as unset, so /etc/hostname names the host.
        assert!(local(
            &target(Some("tv"), "ni"),
            Some("tv"),
            Some(""),
            Some("ni\n")
        ));
        assert!(local(
            &target(Some("tv"), "ni"),
            Some("tv"),
            Some("ni"),
            Some("other\n")
        ));
        assert!(!local(
            &target(Some("tv"), "ni"),
            Some("tv"),
            None,
            Some("a\nb\n")
        ));
        // Labels of any length, like lib.types.label.
        let long = "x".repeat(64);
        assert!(local(
            &target(Some("tv"), &long),
            Some("tv"),
            None,
            Some(&long)
        ));
    }

    #[test]
    fn store_paths() {
        assert!(is_store_path("/nix/store/abc-x"));
        assert!(!is_store_path("/nix/store/abc-x/y"));
        assert!(!is_store_path("/nix/store"));
        assert!(!is_store_path("/etc"));
    }
}
