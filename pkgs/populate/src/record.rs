//! The journal of runs, in the sentinel, and the record of the last run
//! that finished, which sums it up, for consumers of the target directory.
//!
//! The journal has a line of JSON for each entry: {"run": STARTED} when a
//! run starts, {"begin": NAME} before delivering the source NAME, or
//! changing it later, {"end": NAME, "changed": CHANGED, "delivered":
//! DELIVERED} after that, and {"pruned": true} after pruning removed
//! anything.  A run that doesn't finish leaves it there, and the next run
//! adds to it, so the record of the next run that finishes tells what
//! changed since the last record, also what runs that didn't finish
//! changed.

use crate::spec::Spec;
use serde_json::{json, Map, Value};
use std::collections::{BTreeMap, BTreeSet};
use std::time::{SystemTime, UNIX_EPOCH};

/// The version of the record's format.
const VERSION: u64 = 0;

/// The time now, in UTC, like 2026-11-20T12:34:56Z.
pub fn now() -> String {
    let seconds = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or_default();
    timestamp(seconds)
}

/// seconds since the epoch, in UTC, like 2026-11-20T12:34:56Z.
fn timestamp(seconds: u64) -> String {
    let (days, rest) = (seconds / 86400, seconds % 86400);
    // The proleptic Gregorian calendar's date of a day since the epoch,
    // after Howard Hinnant's civil_from_days, with eras of 400 years
    // starting on March 1st.
    let z = days as i64 + 719468;
    let era = z.div_euclid(146097);
    let day_of_era = z.rem_euclid(146097);
    let year_of_era =
        (day_of_era - day_of_era / 1460 + day_of_era / 36524 - day_of_era / 146096) / 365;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let month_index = (5 * day_of_year + 2) / 153;
    let day = day_of_year - (153 * month_index + 2) / 5 + 1;
    let month = if month_index < 10 {
        month_index + 3
    } else {
        month_index - 9
    };
    let year = year_of_era + era * 400 + i64::from(month <= 2);
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}Z",
        rest / 3600,
        rest % 3600 / 60,
        rest % 60
    )
}

/// The record of a run that started at started, delivering spec, with the
/// lines of the journal that runs before it left, and its own entries.
pub fn record(spec: &Spec, started: &str, previous: &[String], entries: &[Value]) -> Value {
    let mut open = BTreeSet::new();
    let mut changed = BTreeSet::new();
    let mut pruned = false;
    let mut delivered: BTreeMap<&str, Map<String, Value>> = BTreeMap::new();
    let mut unreadable = false;
    let previous: Vec<Value> = previous
        .iter()
        .filter(|line| !line.is_empty())
        .filter_map(|line| {
            let entry = serde_json::from_str(line).ok();
            unreadable |= entry.is_none();
            entry
        })
        .collect();
    let current = previous.len();
    for (i, entry) in previous.iter().chain(entries).enumerate() {
        if entry.get("run").is_some() {
            // What a run that didn't finish began may have changed.
            changed.append(&mut open);
        } else if let Some(name) = entry.get("begin").and_then(Value::as_str) {
            open.insert(name.to_string());
        } else if let Some(name) = entry.get("end").and_then(Value::as_str) {
            open.remove(name);
            if entry.get("changed").and_then(Value::as_bool) != Some(false) {
                changed.insert(name.to_string());
            }
            if i >= current {
                if let Some(Value::Object(fields)) = entry.get("delivered") {
                    let fields = fields.clone().into_iter();
                    delivered.entry(name).or_default().extend(fields);
                }
            }
        } else if entry.get("pruned").is_some() {
            pruned = true;
        }
    }
    changed.append(&mut open);
    let sources: Map<String, Value> = spec
        .source
        .iter()
        .map(|(name, source)| {
            let mut fields = Map::new();
            fields.insert("type".to_string(), json!(source.kind));
            fields.insert(
                "changed".to_string(),
                json!(unreadable || changed.contains(name)),
            );
            fields.extend(delivered.remove(name.as_str()).unwrap_or_default());
            (name.clone(), Value::Object(fields))
        })
        .collect();
    json!({
        "version": VERSION,
        "populate": env!("CARGO_PKG_VERSION"),
        "started": started,
        "finished": now(),
        "changed": unreadable || pruned || !changed.is_empty(),
        "sources": sources,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn timestamps() {
        assert_eq!(timestamp(0), "1970-01-01T00:00:00Z");
        assert_eq!(timestamp(951_782_400), "2000-02-29T00:00:00Z");
        assert_eq!(timestamp(1_795_178_096), "2026-11-20T12:34:56Z");
    }
}
