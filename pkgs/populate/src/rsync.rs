//! Transferring with rsync, from the deploying machine to the target.

use crate::run::{self, Context, Failure, Result};
use crate::sh;
use serde_json::{Map, Value};
use std::path::Path;
use std::process::Command;

/// What a transfer excludes and filters, and how it compares files.
pub struct Config {
    pub use_checksum: bool,
    pub exclude: Vec<String>,
    /// Filter rules, as rsync's option without the dashes and its pattern.
    pub filters: Vec<(String, String)>,
    pub delete_excluded: bool,
    /// What to do about .rsync-filter files rsync can't read: fail if None,
    /// make rsync read them anyway if true, sync without them if false.
    pub insecure_links: Option<bool>,
    /// Whether .rsync-filter files apply.
    pub filter_files: bool,
}

impl Default for Config {
    fn default() -> Config {
        Config {
            use_checksum: false,
            exclude: Vec::new(),
            filters: Vec::new(),
            delete_excluded: true,
            insecure_links: None,
            filter_files: true,
        }
    }
}

impl Config {
    /// The defaults, with what a file source's settings say instead.
    pub fn from_settings(settings: &Map<String, Value>) -> Config {
        let mut config = Config::default();
        if let Some(Value::Bool(b)) = settings.get("useChecksum") {
            config.use_checksum = *b;
        }
        if let Some(Value::Array(patterns)) = settings.get("exclude") {
            config.exclude = patterns
                .iter()
                .filter_map(|p| p.as_str().map(String::from))
                .collect();
        }
        if let Some(Value::Array(filters)) = settings.get("filters") {
            config.filters = filters
                .iter()
                .filter_map(|f| {
                    let kind = f.get("type")?.as_str()?;
                    let pattern = f.get("pattern")?.as_str()?;
                    Some((kind.to_string(), pattern.to_string()))
                })
                .collect();
        }
        if let Some(Value::Bool(b)) = settings.get("deleteExcluded") {
            config.delete_excluded = *b;
        }
        if let Some(Value::Bool(b)) = settings.get("insecureLinks") {
            config.insecure_links = Some(*b);
        }
        config
    }

    /// rsync's arguments for what the transfer excludes and filters,
    /// followed by -F, which applies .rsync-filter files, unless the config
    /// turns that off.
    fn filter_args(&self) -> Vec<String> {
        let mut args = Vec::new();
        for pattern in &self.exclude {
            args.extend(["--exclude".to_string(), pattern.clone()]);
        }
        for (kind, pattern) in &self.filters {
            args.extend([format!("--{kind}"), pattern.clone()]);
        }
        if self.filter_files {
            args.push("-F".to_string());
        }
        args
    }
}

/// Transfers source_path, a directory's contents or a file, to path on the
/// target, returning the paths, relative to path, of what that changed
/// there.
pub fn transfer(
    context: &Context,
    config: &Config,
    source_path: &str,
    path: &str,
) -> Result<Vec<String>> {
    context.run(&sh::break_hard_links(), &[path, &context.name(path)])?;
    let mut source = source_path.to_string();
    if Path::new(source_path).is_dir() {
        source.push('/');
    }
    let insecure_links = if config.filter_files {
        insecure_links(context, config, &source)?
    } else {
        false
    };
    let mut command = Command::new("rsync");
    if config.use_checksum {
        command.arg("--checksum");
    }
    // The remote shell runs it as a command.
    let sudo = if context.target.sudo { "sudo " } else { "" };
    match context.path() {
        Some(path) => command.arg(format!(
            "--rsync-path={sudo}env PATH={path}:\"$PATH\" rsync"
        )),
        None if context.target.sudo => command.arg("--rsync-path=sudo rsync"),
        None => &mut command,
    };
    command.arg("-e").arg(&context.ssh).arg("--protect-args");
    if insecure_links {
        command.arg("--insecure-links");
    }
    // Each item gets logged with what changed about it, and its size, as
    // transferred and in total, in units of 1024, which three apostrophes
    // ask for.
    command
        .arg("--itemize-changes")
        .arg("--out-format=%i %n%L %'''b/%'''l")
        .arg("--info=backup,del,copy,misc,mount,name,nonreg,remove,skip,symsafe")
        // Nothing relies on the times of directories and symlinks, and
        // keeping them would log a line for each directory changed.
        .arg("--omit-dir-times")
        .arg("--omit-link-times")
        .args(config.filter_args())
        .arg("-rlptD");
    if config.delete_excluded {
        command.arg("--delete-excluded");
    }
    command.arg(&source).arg(context.rsync_destination(path));
    let mut changed = Vec::new();
    run::lines(&mut command, |line| {
        changed.extend(changed_path(line));
        eprintln!("{line}");
    })?;
    Ok(changed)
}

/// The path of what a line rsync prints itemizes a change of: what
/// --itemize-changes prints for an item, eleven characters, the second the
/// type of the item, or *deleting, followed by a blank, and the path, which
/// the sizes follow for items, and a symlink's target, after ->.
fn changed_path(line: &str) -> Option<String> {
    let (item, rest) = line.split_once(' ')?;
    if item == "*deleting" {
        return Some(rest.trim_start().to_string());
    }
    if item.len() != 11 || !matches!(item.as_bytes()[1], b'f' | b'd' | b'L' | b'D' | b'S') {
        return None;
    }
    let (path, _sizes) = rest.rsplit_once(' ')?;
    let path = if item.as_bytes()[1] == b'L' {
        path.split_once(" -> ").map_or(path, |(path, _)| path)
    } else {
        path
    };
    Some(path.to_string())
}

/// rsync 3.5.0 and later open .rsync-filter files with a stricter walk than
/// the files they transfer, and treat the ones that walk can't open as
/// missing, without saying so.  It fails, e.g., for a directory on the way
/// that the user may enter but not read, like a home directory with mode
/// 711, or a symlink that neither root nor the user owns.  So rsync, when
/// asked, tells which .rsync-filter files it reads for source: the ones
/// therein, and the ones in the directories above it, which apply as well.
/// If it reports ones as missing that exist and that the user may read, the
/// config's insecure_links decides: populate fails with an error if it's
/// None, syncs without them if it's false, and makes rsync open them like
/// the files it transfers with --insecure-links if it's true, both with a
/// warning.  Returns whether rsync needs --insecure-links.
fn insecure_links(context: &Context, config: &Config, source: &str) -> Result<bool> {
    let version_line = run::output(Command::new("rsync").arg("--version"))?;
    let version = version_line
        .lines()
        .next()
        .and_then(|line| line.split_whitespace().nth(2))
        .unwrap_or("")
        .to_string();
    // Also with older versions of rsync, so a source that's missing, or
    // that contains a directory find can't read, fails before rsync runs.
    let filtered = filtered(source)?;
    if !version_at_least(&version, "3.5.0") || !filtered {
        return Ok(false);
    }
    // A dry run of the same transfer, as far as filtering goes.
    let log = run::output(
        Command::new(run::SH)
            .arg("-c")
            .arg(r#"rsync "$@" 2>&1 || :"#)
            .arg("sh")
            .args(["--dry-run", "--debug=FILTER2"])
            .args(config.filter_args())
            .arg("-rlptD")
            .arg(source)
            .arg(context.tmpdir.join("rsync-filter-check")),
    )?;
    let mut parsed = false;
    let mut ignored = None;
    for line in log.lines() {
        let Some(rest) = line.strip_prefix("[sender] parse_filter_file(") else {
            continue;
        };
        parsed = true;
        let Some(rest) = rest.strip_suffix(") [not found]") else {
            continue;
        };
        // What precedes the last two comma-separated fields.
        let Some(file) = rest.rsplitn(3, ',').nth(2) else {
            continue;
        };
        let file = unescape(file);
        let shown = file.display().to_string();
        let readable = std::fs::File::open(&file).is_ok();
        if Path::new(&file).exists() && readable {
            ignored = Some(shown);
            break;
        }
    }
    if !parsed {
        eprintln!(
            "warning: rsync {version} doesn't tell which .rsync-filter files it reads, so it may sync {source} without some of them unnoticed."
        );
    }
    let Some(ignored) = ignored else {
        return Ok(false);
    };
    match config.insecure_links {
        None => Err(Failure::Message(format!(
            "error: rsync {version} can't read {ignored}, so it would sync {source} without it.  This happens, e.g., if a directory on the way isn't readable, or if a symlink on the way belongs to neither root nor the user running rsync.  Set the source's insecureLinks to true to make rsync read it anyway, or to false to sync without it."
        ))),
        Some(true) => {
            eprintln!(
                "warning: rsync {version} can't read {ignored}; it reads it with --insecure-links anyway, because insecureLinks is true."
            );
            Ok(true)
        }
        Some(false) => {
            eprintln!(
                "warning: rsync {version} can't read {ignored}, so it syncs {source} without it, because insecureLinks is false."
            );
            Ok(false)
        }
    }
}

/// Whether a .rsync-filter file applies to source: one therein, or in a
/// directory above it.  Fails, with find's message, if find fails.
fn filtered(source: &str) -> Result<bool> {
    let found = run::output(Command::new("find").arg(source).args([
        "-name",
        ".rsync-filter",
        "-print",
        "-quit",
    ]))?;
    if !found.is_empty() {
        return Ok(true);
    }
    let mut above = parent(source);
    loop {
        if Path::new(&above).join(".rsync-filter").exists() {
            return Ok(true);
        }
        if above == "/" || above == "." {
            return Ok(false);
        }
        above = parent(&above);
    }
}

/// Like dirname.
fn parent(path: &str) -> String {
    let trimmed = path.trim_end_matches('/');
    if trimmed.is_empty() {
        return "/".to_string();
    }
    match trimmed.rfind('/') {
        None => ".".to_string(),
        Some(i) => {
            let parent = trimmed[..i].trim_end_matches('/');
            if parent.is_empty() { "/" } else { parent }.to_string()
        }
    }
}

/// Like sort -V: whether version is at least minimum.
fn version_at_least(version: &str, minimum: &str) -> bool {
    let parts = |v: &str| -> Vec<u64> {
        v.split('.')
            .map(|p| {
                p.chars()
                    .take_while(char::is_ascii_digit)
                    .collect::<String>()
            })
            .map(|p| p.parse().unwrap_or(0))
            .collect()
    };
    parts(version) >= parts(minimum)
}

/// rsync prints bytes it takes for unprintable, which depends on the
/// locale, as \#ooo.
fn unescape(escaped: &str) -> std::path::PathBuf {
    use std::os::unix::ffi::OsStringExt;
    let bytes = escaped.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        let octal = bytes
            .get(i + 2..i + 5)
            .filter(|d| d.iter().all(|b| (b'0'..=b'7').contains(b)));
        let escape = bytes[i] == b'\\' && bytes.get(i + 1) == Some(&b'#');
        if let (true, Some(digits)) = (escape, octal) {
            let value = digits
                .iter()
                .fold(0u32, |acc, d| acc * 8 + u32::from(d - b'0'));
            out.push(value as u8);
            i += 5;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    std::ffi::OsString::from_vec(out).into()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn changed_paths() {
        let path = |line| changed_path(line);
        assert_eq!(
            path(">f.st...... flake.nix 82/39").as_deref(),
            Some("flake.nix")
        );
        assert_eq!(path("cd+++++++++ a b/ 0/4.00K").as_deref(), Some("a b/"));
        assert_eq!(path(".f..t...... x 0/1").as_deref(), Some("x"));
        assert_eq!(path("cL+++++++++ l -> t 0/0").as_deref(), Some("l"));
        assert_eq!(path("*deleting   old").as_deref(), Some("old"));
        assert_eq!(path("skipping non-regular file \"x\""), None);
        assert_eq!(path("sent 10 bytes"), None);
    }

    #[test]
    fn versions() {
        assert!(version_at_least("3.5.0", "3.5.0"));
        assert!(version_at_least("3.10.1", "3.5.0"));
        assert!(!version_at_least("3.4.1", "3.5.0"));
    }

    #[test]
    fn parents() {
        assert_eq!(parent("/a/b/"), "/a");
        assert_eq!(parent("/a"), "/");
        assert_eq!(parent("a"), ".");
        assert_eq!(parent("/"), "/");
    }

    #[test]
    fn unescaping() {
        assert_eq!(unescape(r"a\#012b"), std::path::PathBuf::from("a\nb"));
        assert_eq!(unescape(r"a\#9b"), std::path::PathBuf::from(r"a\#9b"));
    }
}
