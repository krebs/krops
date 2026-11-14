//! populate's command line.

use crate::spec::TargetParts;

/// What the command line asks for.
#[derive(Debug, PartialEq)]
pub enum Command {
    /// Printing a usage, USAGE or SHELL_USAGE.
    Help(&'static str),
    Version,
    Populate(Options),
    Shell(ShellOptions),
}

/// The arguments of populating.
#[derive(Debug, Default, PartialEq)]
pub struct Options {
    pub backup: bool,
    pub force: bool,
    pub prune: bool,
    /// The file the sources are in, or - for standard input.
    pub sources: String,
    /// The target, as given, with the options changing its parts applied.
    pub target: TargetParts,
    pub sudo: bool,
    pub ssh_args: Vec<String>,
    /// Whether the target is the machine populate runs on, if --local or
    /// --remote says so.
    pub local: Option<bool>,
}

/// The arguments of populate shell.
#[derive(Debug, Default, PartialEq)]
pub struct ShellOptions {
    /// The target, as given, with the options changing its parts applied.
    pub target: TargetParts,
    pub sudo: bool,
    pub ssh_args: Vec<String>,
    /// Whether the target is the machine populate runs on, if --local or
    /// --remote says so.
    pub local: Option<bool>,
    /// Whether the script gets a terminal on a remote target.
    pub tty: bool,
    /// Whether to fail unless the target is local.
    pub local_only: bool,
    /// The shell code to run.
    pub script: String,
}

pub const USAGE: &str = "\
usage: populate [OPTION]... SOURCES [TARGET]
       populate shell [OPTION]... TARGET SCRIPT

Delivers the sources in the file SOURCES, a JSON object, or standard input
if SOURCES is -, to the target directory TARGET.

TARGET is [USER@][HOST][:PORT][PATH].  USER defaults to $LOGNAME, HOST to
the name of the machine, and PATH to /var/src.  A target is local if its
user is $LOGNAME, and its host is localhost or the name of the machine;
populate reaches other targets via ssh.

Options:
  --backup        copy the target directory to a backup first
  --force         create the target directory's sentinel if it's missing
  --prune         remove what isn't a source from the target directory
  --sudo          deliver as root, via sudo on the target
  --ssh-arg ARG   pass ARG to ssh; repeatable
  --user USER     the target's user; empty for ssh's default
  --host HOST     the target's host
  --port PORT     the port ssh connects to
  --path PATH     the target directory
  --local         the target is the machine populate runs on
  --remote        the target isn't, even if it looks so
  -h, --help      print this and exit
  -V, --version   print populate's version and exit

See populate shell --help for populate shell.
";

pub const SHELL_USAGE: &str = "\
usage: populate shell [OPTION]... TARGET SCRIPT

Runs the shell code SCRIPT with /bin/sh on TARGET, reached like populate
reaches it, with local or remote as $1, telling whether TARGET is local.
TARGET is like populate's, with its path left unused.  The exit status is
SCRIPT's, or ssh's if ssh fails.

Options:
  --sudo          run SCRIPT as root, via sudo on the target
  --ssh-arg ARG   pass ARG to ssh; repeatable
  --user USER     the target's user; empty for ssh's default
  --host HOST     the target's host
  --port PORT     the port ssh connects to
  --local         the target is the machine populate runs on
  --remote        the target isn't, even if it looks so
  --tty           give SCRIPT a terminal, if the target is remote
  --local-only    fail, without running SCRIPT, unless the target is local
  -h, --help      print this and exit
";

/// What the options and arguments common to populate and populate shell
/// say.
#[derive(Default)]
struct Parsed {
    /// The flags given, among those the command takes.
    flags: Vec<&'static str>,
    ssh_args: Vec<String>,
    /// --user, --host, --port, and --path, in order.
    overrides: Vec<(&'static str, String)>,
    positional: Vec<String>,
    help: bool,
    version: bool,
}

/// Parses args, with the flags among flags, and the options with an
/// argument among options.  Options and the other arguments may come in any
/// order, up to --.
fn parse_args(
    args: &[String],
    flags: &[&'static str],
    options: &[&'static str],
) -> Result<Parsed, String> {
    let mut parsed = Parsed::default();
    let mut args = args.iter();
    while let Some(arg) = args.next() {
        if arg == "--" {
            parsed.positional.extend(args.by_ref().cloned());
            break;
        }
        if arg == "-" || !arg.starts_with('-') {
            parsed.positional.push(arg.clone());
            continue;
        }
        let (name, inline) = match arg.split_once('=') {
            Some((name, value)) if name.starts_with("--") => (name, Some(value.to_string())),
            _ => (arg.as_str(), None),
        };
        if let Some(flag) = flags.iter().find(|f| **f == name) {
            if inline.is_some() {
                return Err(format!("option {name} takes no argument"));
            }
            match *flag {
                "-h" | "--help" => parsed.help = true,
                "-V" | "--version" => parsed.version = true,
                flag => parsed.flags.push(flag),
            }
            if parsed.help || parsed.version {
                return Ok(parsed);
            }
            continue;
        }
        let Some(option) = options.iter().find(|o| **o == name) else {
            return Err(format!("unknown option {name}"));
        };
        let value = match inline {
            Some(value) => value,
            None => args
                .next()
                .cloned()
                .ok_or_else(|| format!("option {name} needs an argument"))?,
        };
        match *option {
            "--ssh-arg" => parsed.ssh_args.push(value),
            option => parsed
                .overrides
                .push((option.trim_start_matches("--"), value)),
        }
    }
    Ok(parsed)
}

impl Parsed {
    fn has(&self, flag: &str) -> bool {
        self.flags.contains(&flag)
    }

    /// Whether --local or --remote says the target is local, the last of
    /// them winning.
    fn local(&self) -> Option<bool> {
        self.flags.iter().rev().find_map(|flag| match *flag {
            "--local" => Some(true),
            "--remote" => Some(false),
            _ => None,
        })
    }

    /// The target text, with the options changing its parts applied.
    fn target(&self, text: &str) -> Result<TargetParts, String> {
        let mut target = TargetParts::parse(text)?;
        for (part, value) in &self.overrides {
            let value = Some(value.clone());
            match *part {
                "user" => target.user = value,
                "host" => target.host = value,
                "port" => target.port = value,
                _ => target.path = value,
            }
        }
        if let Some(path) = &target.path {
            if path.is_empty() {
                return Err("the target's path is empty".to_string());
            }
        }
        Ok(target)
    }
}

/// The command line, without the program's name.
pub fn parse(args: &[String]) -> Result<Command, String> {
    match args.split_first() {
        Some((first, rest)) if first == "shell" => parse_shell(rest),
        _ => parse_populate(args),
    }
}

fn parse_populate(args: &[String]) -> Result<Command, String> {
    let parsed = parse_args(
        args,
        &[
            "-h",
            "--help",
            "-V",
            "--version",
            "--backup",
            "--force",
            "--prune",
            "--sudo",
            "--local",
            "--remote",
        ],
        &["--ssh-arg", "--user", "--host", "--port", "--path"],
    )?;
    if parsed.help {
        return Ok(Command::Help(USAGE));
    }
    if parsed.version {
        return Ok(Command::Version);
    }
    let (sources, target) = match parsed.positional.as_slice() {
        [sources] => (sources.clone(), String::new()),
        [sources, target] => (sources.clone(), target.clone()),
        [] => return Err("SOURCES is missing".to_string()),
        _ => return Err("too many arguments".to_string()),
    };
    Ok(Command::Populate(Options {
        backup: parsed.has("--backup"),
        force: parsed.has("--force"),
        prune: parsed.has("--prune"),
        sources,
        target: parsed.target(&target)?,
        sudo: parsed.has("--sudo"),
        local: parsed.local(),
        ssh_args: parsed.ssh_args,
    }))
}

fn parse_shell(args: &[String]) -> Result<Command, String> {
    let parsed = parse_args(
        args,
        &[
            "-h",
            "--help",
            "--sudo",
            "--local",
            "--remote",
            "--tty",
            "--local-only",
        ],
        &["--ssh-arg", "--user", "--host", "--port"],
    )?;
    if parsed.help {
        return Ok(Command::Help(SHELL_USAGE));
    }
    let (target, script) = match parsed.positional.as_slice() {
        [target, script] => (target.clone(), script.clone()),
        [] | [_] => return Err("shell: TARGET and SCRIPT are missing".to_string()),
        _ => return Err("shell: too many arguments".to_string()),
    };
    Ok(Command::Shell(ShellOptions {
        target: parsed.target(&target)?,
        sudo: parsed.has("--sudo"),
        local: parsed.local(),
        tty: parsed.has("--tty"),
        local_only: parsed.has("--local-only"),
        script,
        ssh_args: parsed.ssh_args,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(args: &[&str]) -> Result<Command, String> {
        super::parse(&args.iter().map(|a| a.to_string()).collect::<Vec<_>>())
    }

    fn options(args: &[&str]) -> Options {
        match parse(args) {
            Ok(Command::Populate(options)) => options,
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn targets() {
        let o = options(&["s.json", "root@host:2222/var/src"]);
        assert_eq!(o.sources, "s.json");
        assert_eq!(
            o.target,
            TargetParts {
                user: Some("root".to_string()),
                host: Some("host".to_string()),
                port: Some("2222".to_string()),
                path: Some("/var/src".to_string()),
            }
        );
        assert_eq!(options(&["-"]).target, TargetParts::default());
        let o = options(&["--host", "2001:db8::1", "-", "root@x", "--port=22"]);
        assert_eq!(o.target.user.as_deref(), Some("root"));
        assert_eq!(o.target.host.as_deref(), Some("2001:db8::1"));
        assert_eq!(o.target.port.as_deref(), Some("22"));
    }

    #[test]
    fn flags() {
        let o = options(&[
            "--backup",
            "--prune",
            "--sudo",
            "--ssh-arg",
            "-o",
            "--ssh-arg=X=y",
            "--remote",
            "s",
        ]);
        assert!(o.backup && o.prune && o.sudo && !o.force);
        assert_eq!(o.ssh_args, ["-o", "X=y"]);
        assert_eq!(o.local, Some(false));
        // After --, arguments are no options.
        assert_eq!(options(&["--", "--sources"]).sources, "--sources");
    }

    fn shell_options(args: &[&str]) -> ShellOptions {
        match parse(args) {
            Ok(Command::Shell(options)) => options,
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn shell() {
        let o = shell_options(&[
            "shell",
            "--sudo",
            "--tty",
            "--ssh-arg=-v",
            "--port",
            "22",
            "root@host",
            "echo $1",
        ]);
        assert!(o.sudo && o.tty && !o.local_only);
        assert_eq!(o.ssh_args, ["-v"]);
        assert_eq!(o.target.user.as_deref(), Some("root"));
        assert_eq!(o.target.port.as_deref(), Some("22"));
        assert_eq!(o.script, "echo $1");
        assert_eq!(o.local, None);
        let o = shell_options(&[
            "shell",
            "--local",
            "--remote",
            "--local-only",
            "",
            "--",
            "-x",
        ]);
        assert_eq!(o.local, Some(false));
        assert!(o.local_only);
        assert_eq!(o.target, TargetParts::default());
        assert_eq!(o.script, "-x");
        assert_eq!(parse(&["shell", "-h"]), Ok(Command::Help(SHELL_USAGE)));
        assert_eq!(
            parse(&["shell", "x"]),
            Err("shell: TARGET and SCRIPT are missing".to_string())
        );
        assert_eq!(
            parse(&["shell", "--backup", "x", "y"]),
            Err("unknown option --backup".to_string())
        );
        assert_eq!(
            parse(&["shell", "--path", "/x", "x", "y"]),
            Err("unknown option --path".to_string())
        );
        // A file named shell is ./shell.
        assert_eq!(options(&["./shell"]).sources, "./shell");
    }

    #[test]
    fn errors() {
        assert_eq!(parse(&["--help", "--bogus"]), Ok(Command::Help(USAGE)));
        assert_eq!(
            parse(&["--bogus"]),
            Err("unknown option --bogus".to_string())
        );
        assert_eq!(parse(&[]), Err("SOURCES is missing".to_string()));
        assert_eq!(
            parse(&["a", "b", "c"]),
            Err("too many arguments".to_string())
        );
        assert_eq!(
            parse(&["s", "--user"]),
            Err("option --user needs an argument".to_string())
        );
        assert_eq!(
            parse(&["--prune=yes", "s"]),
            Err("option --prune takes no argument".to_string())
        );
        assert!(parse(&["s", "host:"]).is_err());
    }
}
