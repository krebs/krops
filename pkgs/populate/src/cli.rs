//! populate's command line.

use crate::spec::TargetParts;

/// What the command line asks for.
#[derive(Debug, PartialEq)]
pub enum Command {
    Help,
    Version,
    Populate(Options),
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

pub const USAGE: &str = "\
usage: populate [OPTION]... SOURCES [TARGET]

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
";

/// The command line, without the program's name.  Options and the other
/// arguments may come in any order, up to --.
pub fn parse(args: &[String]) -> Result<Command, String> {
    let mut options = Options::default();
    let mut positional: Vec<String> = Vec::new();
    let mut overrides: Vec<(&'static str, String)> = Vec::new();
    let mut args = args.iter();
    while let Some(arg) = args.next() {
        if arg == "--" {
            positional.extend(args.by_ref().cloned());
            break;
        }
        if arg == "-" || !arg.starts_with('-') {
            positional.push(arg.clone());
            continue;
        }
        let (name, inline) = match arg.split_once('=') {
            Some((name, value)) if name.starts_with("--") => (name, Some(value.to_string())),
            _ => (arg.as_str(), None),
        };
        let mut value = |name: &str| -> Result<String, String> {
            match &inline {
                Some(value) => Ok(value.clone()),
                None => args
                    .next()
                    .cloned()
                    .ok_or_else(|| format!("option {name} needs an argument")),
            }
        };
        match name {
            "-h" | "--help" => return Ok(Command::Help),
            "-V" | "--version" => return Ok(Command::Version),
            "--backup" => options.backup = true,
            "--force" => options.force = true,
            "--prune" => options.prune = true,
            "--sudo" => options.sudo = true,
            "--local" => options.local = Some(true),
            "--remote" => options.local = Some(false),
            "--ssh-arg" => options.ssh_args.push(value(name)?),
            "--user" => overrides.push(("user", value(name)?)),
            "--host" => overrides.push(("host", value(name)?)),
            "--port" => overrides.push(("port", value(name)?)),
            "--path" => overrides.push(("path", value(name)?)),
            _ => return Err(format!("unknown option {name}")),
        }
        if inline.is_some()
            && matches!(
                name,
                "--backup" | "--force" | "--prune" | "--sudo" | "--local" | "--remote"
            )
        {
            return Err(format!("option {name} takes no argument"));
        }
    }
    let (sources, target) = match positional.as_slice() {
        [sources] => (sources.clone(), String::new()),
        [sources, target] => (sources.clone(), target.clone()),
        [] => return Err("SOURCES is missing".to_string()),
        _ => return Err("too many arguments".to_string()),
    };
    options.sources = sources;
    options.target = TargetParts::parse(&target)?;
    for (part, value) in overrides {
        let target = &mut options.target;
        match part {
            "user" => target.user = Some(value),
            "host" => target.host = Some(value),
            "port" => target.port = Some(value),
            _ => target.path = Some(value),
        }
    }
    if let Some(path) = &options.target.path {
        if path.is_empty() {
            return Err("the target's path is empty".to_string());
        }
    }
    Ok(Command::Populate(options))
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

    #[test]
    fn errors() {
        assert_eq!(parse(&["--help", "--bogus"]), Ok(Command::Help));
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
