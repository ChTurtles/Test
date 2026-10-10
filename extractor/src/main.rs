//! rsf-extract: reads Deep Rock Galactic gear stats from the player's own DRG install and writes
//! them as a Lua table for the Rock and Stone Frontier UE4SS mod in Far Far West.
//!
//!   rsf-extract --drg "<Deep Rock Galactic folder>" --out "<mod>/data/drg_stats.lua"
//!
//! The output file is always written (Melty's setup step waits for it). When the pak cannot be read,
//! it carries `ok = false` and the reason, and the mod falls back to the stats in the sheets.

#![cfg_attr(windows, windows_subsystem = "windows")]

mod uasset;

use serde::Deserialize;
use std::collections::BTreeMap;
use std::fmt::Write as _;
use std::fs::File;
use std::io::BufReader;
use std::path::{Path, PathBuf};

const VERSION: &str = env!("CARGO_PKG_VERSION");

#[derive(Deserialize)]
struct Targets {
    sources: Vec<Source>,
    gear: Vec<Gear>,
}

#[derive(Deserialize)]
struct Source {
    id: String,
    asset_globs: Vec<String>,
    stats: Vec<Stat>,
}

#[derive(Deserialize)]
struct Stat {
    id: String,
    candidates: Vec<String>,
    scale: f64,
    value_type: String,
}

#[derive(Deserialize)]
struct Gear {
    id: String,
    sheet: String,
    source: String,
}

struct Picked {
    value: f64,
    from: String,
}

fn glob_match(pattern: &str, text: &str) -> bool {
    let p: Vec<char> = pattern.to_ascii_lowercase().chars().collect();
    let t: Vec<char> = text.to_ascii_lowercase().chars().collect();
    let (mut pi, mut ti, mut star, mut mark) = (0usize, 0usize, None::<usize>, 0usize);
    while ti < t.len() {
        if pi < p.len() && (p[pi] == t[ti] || p[pi] == '?') {
            pi += 1;
            ti += 1;
        } else if pi < p.len() && p[pi] == '*' {
            star = Some(pi);
            pi += 1;
            mark = ti;
        } else if let Some(s) = star {
            pi = s + 1;
            mark += 1;
            ti = mark;
        } else {
            return false;
        }
    }
    while pi < p.len() && p[pi] == '*' {
        pi += 1;
    }
    pi == p.len()
}

fn lua_str(s: &str) -> String {
    let mut o = String::from("\"");
    for ch in s.chars() {
        match ch {
            '\\' => o.push_str("\\\\"),
            '"' => o.push_str("\\\""),
            '\n' => o.push_str("\\n"),
            '\r' => {}
            c if (c as u32) < 0x20 => {}
            c => o.push(c),
        }
    }
    o.push('"');
    o
}

fn lua_num(v: f64) -> String {
    if v.is_finite() { format!("{v}") } else { "0".into() }
}

fn find_pak(drg: &Path) -> Option<PathBuf> {
    let paks = drg.join("FSD").join("Content").join("Paks");
    let main = paks.join("FSD-WindowsNoEditor.pak");
    if main.is_file() {
        return Some(main);
    }
    std::fs::read_dir(&paks).ok()?.flatten().map(|e| e.path()).find(|p| {
        p.extension().map(|x| x == "pak").unwrap_or(false)
            && p.file_name().map(|n| n.to_string_lossy().starts_with("FSD")).unwrap_or(false)
    })
}

struct Report {
    log: String,
    stats: BTreeMap<String, BTreeMap<String, Picked>>,
    error: Option<String>,
    pak: String,
}

fn extract(drg: &Path, targets: &Targets) -> Report {
    let mut r = Report { log: String::new(), stats: BTreeMap::new(), error: None, pak: String::new() };
    let Some(pak_path) = find_pak(drg) else {
        r.error = Some(format!("no FSD pak under {}", drg.join("FSD/Content/Paks").display()));
        return r;
    };
    r.pak = pak_path.display().to_string();
    let file = match File::open(&pak_path) {
        Ok(f) => f,
        Err(e) => {
            r.error = Some(format!("cannot open {}: {e}", pak_path.display()));
            return r;
        }
    };
    let mut reader = BufReader::with_capacity(1 << 20, file);
    let pak = match repak::PakBuilder::new().reader(&mut reader) {
        Ok(p) => p,
        Err(e) => {
            r.error = Some(format!("cannot read pak index: {e}"));
            return r;
        }
    };
    let files = pak.files();
    let _ = writeln!(r.log, "pak {} version {:?} mount {} files {} compression {:?}",
        pak_path.display(), pak.version(), pak.mount_point(), files.len(), pak.used_compression());

    let mut by_source: BTreeMap<String, BTreeMap<String, Picked>> = BTreeMap::new();
    for src in &targets.sources {
        let mut matched: Vec<&String> = Vec::new();
        for g in &src.asset_globs {
            for f in &files {
                let full = format!("/{f}");
                if full.ends_with(".uasset") && glob_match(g, &full) && !matched.contains(&f) {
                    matched.push(f);
                }
            }
        }
        let _ = writeln!(r.log, "\n[{}] {} asset(s) matched", src.id, matched.len());
        let mut found_all: Vec<(String, uasset::Found)> = Vec::new();
        for f in matched.iter().take(40) {
            let uexp_path = format!("{}.uexp", f.trim_end_matches(".uasset"));
            let ua = match pak.get(f, &mut reader) {
                Ok(b) => b,
                Err(e) => {
                    let _ = writeln!(r.log, "  {f}: read failed: {e}");
                    continue;
                }
            };
            let ue = pak.get(&uexp_path, &mut reader).unwrap_or_default();
            match uasset::Package::parse(&ua) {
                Ok(p) => {
                    let mut errors = Vec::new();
                    let nums = p.numbers(&ue, &mut errors);
                    let _ = writeln!(r.log, "  {f}: {} export(s), {} number(s)", p.exports.len(), nums.len());
                    for e in errors.iter().take(5) {
                        let _ = writeln!(r.log, "    skipped {e}");
                    }
                    for n in nums {
                        let _ = writeln!(r.log, "    {}.{} = {}", n.export, n.path, n.value);
                        found_all.push((f.to_string(), n));
                    }
                }
                Err(e) => {
                    let _ = writeln!(r.log, "  {f}: parse failed: {e}");
                }
            }
        }
        let mut picked = BTreeMap::new();
        for stat in &src.stats {
            'cand: for cand in &stat.candidates {
                // Class default objects first, then component templates and the rest, in file order.
                for cdo_pass in [true, false] {
                    for (file, n) in &found_all {
                        if n.leaf == *cand && n.export.starts_with("Default__") == cdo_pass {
                            let mut v = n.value * stat.scale;
                            if stat.value_type == "int" {
                                v = v.round();
                            }
                            let from = format!("{}:{}.{}", file, n.export, n.path);
                            let _ = writeln!(r.log, "  -> {} = {} (from {})", stat.id, v, from);
                            picked.insert(stat.id.clone(), Picked { value: v, from });
                            break 'cand;
                        }
                    }
                }
            }
            if !picked.contains_key(&stat.id) {
                let _ = writeln!(r.log, "  -> {} not found (mod uses the sheet value)", stat.id);
            }
        }
        by_source.insert(src.id.clone(), picked);
    }
    for g in &targets.gear {
        if let Some(p) = by_source.get(&g.source) {
            let copy = p.iter().map(|(k, v)| (k.clone(), Picked { value: v.value, from: v.from.clone() })).collect();
            r.stats.insert(g.id.clone(), copy);
        }
        let _ = &g.sheet;
    }
    r
}

fn write_lua(out: &Path, r: &Report, drg: &Path) -> std::io::Result<()> {
    let mut s = String::new();
    s.push_str("-- Written by rsf-extract from this PC's Deep Rock Galactic install. Rebuilt when DRG changes.\n");
    s.push_str("return {\n");
    let _ = writeln!(s, "  ok = {},", r.error.is_none());
    let _ = writeln!(s, "  extractor = {},", lua_str(VERSION));
    let _ = writeln!(s, "  drg = {},", lua_str(&drg.display().to_string()));
    let _ = writeln!(s, "  pak = {},", lua_str(&r.pak));
    let _ = writeln!(s, "  stamp = {},", lua_str(&stamp(drg)));
    let _ = writeln!(s, "  error = {},", r.error.as_deref().map(lua_str).unwrap_or_else(|| "nil".into()));
    s.push_str("  gear = {\n");
    for (gear, stats) in &r.stats {
        let _ = write!(s, "    [{}] = {{", lua_str(gear));
        for (k, v) in stats {
            let _ = write!(s, " {} = {},", k, lua_num(v.value));
        }
        s.push_str(" _from = {");
        for (k, v) in stats {
            let _ = write!(s, " {} = {},", k, lua_str(&v.from));
        }
        s.push_str(" } },\n");
    }
    s.push_str("  },\n}\n");
    if let Some(dir) = out.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let tmp = out.with_extension("lua.tmp");
    std::fs::write(&tmp, s)?;
    std::fs::rename(&tmp, out)
}

/// Size and modified time of the DRG pak, so the mod can tell when DRG updated.
fn stamp(drg: &Path) -> String {
    find_pak(drg)
        .and_then(|p| std::fs::metadata(p).ok())
        .map(|m| {
            let t = m.modified().ok().and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok()).map(|d| d.as_secs()).unwrap_or(0);
            format!("{}-{}", m.len(), t)
        })
        .unwrap_or_default()
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let mut drg = None;
    let mut out = None;
    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--drg" if i + 1 < args.len() => { drg = Some(PathBuf::from(&args[i + 1])); i += 1; }
            "--out" if i + 1 < args.len() => { out = Some(PathBuf::from(&args[i + 1])); i += 1; }
            "--version" => { println!("rsf-extract {VERSION}"); return; }
            _ => {}
        }
        i += 1;
    }
    let exe_dir = std::env::current_exe().ok().and_then(|p| p.parent().map(Path::to_path_buf)).unwrap_or_default();
    // Default output: <mod>/data/drg_stats.lua, the exe living in <mod>/tools.
    let out = out.unwrap_or_else(|| exe_dir.join("..").join("data").join("drg_stats.lua"));
    let Some(drg) = drg else {
        eprintln!("usage: rsf-extract --drg <Deep Rock Galactic folder> [--out <file.lua>]");
        let r = Report { log: String::new(), stats: BTreeMap::new(), error: Some("no --drg folder given".into()), pak: String::new() };
        let _ = write_lua(&out, &r, Path::new(""));
        std::process::exit(2);
    };
    let targets: Targets = serde_json::from_str(include_str!("../targets.json")).expect("targets.json");
    let r = extract(&drg, &targets);
    let log_path = out.with_file_name("drg_extract.log");
    let mut log = format!("rsf-extract {VERSION}\ndrg {}\n", drg.display());
    if let Some(e) = &r.error {
        let _ = writeln!(log, "ERROR {e}");
    }
    log.push_str(&r.log);
    let _ = std::fs::create_dir_all(log_path.parent().unwrap_or(Path::new(".")));
    let _ = std::fs::write(&log_path, log);
    if let Err(e) = write_lua(&out, &r, &drg) {
        eprintln!("cannot write {}: {e}", out.display());
        std::process::exit(1);
    }
    let found: usize = r.stats.values().map(|m| m.len()).sum();
    println!("wrote {} ({} stats from DRG{})", out.display(), found,
        r.error.as_ref().map(|e| format!("; {e}")).unwrap_or_default());
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn globs() {
        assert!(glob_match("*/WeaponsNTools/AssaultRifle/WPN_AssaultRifle.uasset", "/FSD/Content/WeaponsNTools/AssaultRifle/WPN_AssaultRifle.uasset"));
        assert!(glob_match("*/Grenades/*Sticky*.uasset", "/FSD/Content/WeaponsNTools/Grenades/Sticky/PRJ_StickyGrenade.uasset"));
        assert!(!glob_match("*/Revolver/*.uasset", "/FSD/Content/WeaponsNTools/Revolver/WPN_Revolver.uexp"));
    }

    #[test]
    fn lua_strings_escape() {
        assert_eq!(lua_str("a\"b\\c"), "\"a\\\"b\\\\c\"");
    }

    #[test]
    fn missing_drg_folder_still_writes_output() {
        let dir = std::env::temp_dir().join(format!("rsf-test-{}", std::process::id()));
        let targets: Targets = serde_json::from_str(include_str!("../targets.json")).unwrap();
        let r = extract(&dir.join("nope"), &targets);
        assert!(r.error.is_some());
        let out = dir.join("drg_stats.lua");
        write_lua(&out, &r, &dir).unwrap();
        let text = std::fs::read_to_string(&out).unwrap();
        assert!(text.contains("ok = false"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A real pak written with repak, holding a package with a weapon CDO, read back end to end.
    #[test]
    fn reads_stats_from_a_pak() {
        let dir = std::env::temp_dir().join(format!("rsf-pak-{}", std::process::id()));
        let paks = dir.join("FSD/Content/Paks");
        std::fs::create_dir_all(&paks).unwrap();
        let (ua, ue) = crate::uasset_test_sample();
        let f = File::create(paks.join("FSD-WindowsNoEditor.pak")).unwrap();
        let mut w = repak::PakBuilder::new()
            .compression([repak::Compression::Zlib])
            .writer(std::io::BufWriter::new(f), repak::Version::V11, "../../../".into(), None);
        w.write_file("FSD/Content/WeaponsNTools/AssaultRifle/WPN_AssaultRifle.uasset", true, ua).unwrap();
        w.write_file("FSD/Content/WeaponsNTools/AssaultRifle/WPN_AssaultRifle.uexp", true, ue).unwrap();
        w.write_index().unwrap();
        let targets: Targets = serde_json::from_str(include_str!("../targets.json")).unwrap();
        let r = extract(&dir, &targets);
        assert!(r.error.is_none(), "{:?}\n{}", r.error, r.log);
        let gk2 = r.stats.get("gk2").expect("gk2 stats");
        assert_eq!(gk2.get("damage").map(|p| p.value), Some(15.5), "{}", r.log);
        assert_eq!(gk2.get("clip_size").map(|p| p.value), Some(30.0));
        assert_eq!(gk2.get("rate_of_fire").map(|p| p.value), Some(7.0));
        let _ = std::fs::remove_dir_all(&dir);
    }
}

#[cfg(test)]
pub fn uasset_test_sample() -> (Vec<u8>, Vec<u8>) {
    uasset::test_sample()
}
