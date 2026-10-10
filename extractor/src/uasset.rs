//! Minimal reader for cooked UE 4.27 packages (.uasset + .uexp) with tagged properties, enough to
//! pull numbers out of Deep Rock Galactic's weapon, grenade and turret blueprints.

use std::fmt;

#[derive(Debug)]
pub struct ParseError(pub String);

impl fmt::Display for ParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

type Result<T> = std::result::Result<T, ParseError>;

fn err<T>(msg: impl Into<String>) -> Result<T> {
    Err(ParseError(msg.into()))
}

struct Cursor<'a> {
    data: &'a [u8],
    pos: usize,
}

impl<'a> Cursor<'a> {
    fn new(data: &'a [u8], pos: usize) -> Self {
        Cursor { data, pos }
    }
    fn take(&mut self, n: usize) -> Result<&'a [u8]> {
        if n > self.data.len().saturating_sub(self.pos) {
            return err(format!("read past end at {} (+{})", self.pos, n));
        }
        let s = &self.data[self.pos..self.pos + n];
        self.pos += n;
        Ok(s)
    }
    fn u8(&mut self) -> Result<u8> {
        Ok(self.take(1)?[0])
    }
    fn i32(&mut self) -> Result<i32> {
        Ok(i32::from_le_bytes(self.take(4)?.try_into().unwrap()))
    }
    fn u32(&mut self) -> Result<u32> {
        Ok(u32::from_le_bytes(self.take(4)?.try_into().unwrap()))
    }
    fn i64(&mut self) -> Result<i64> {
        Ok(i64::from_le_bytes(self.take(8)?.try_into().unwrap()))
    }
    fn f32(&mut self) -> Result<f32> {
        Ok(f32::from_le_bytes(self.take(4)?.try_into().unwrap()))
    }
    fn f64(&mut self) -> Result<f64> {
        Ok(f64::from_le_bytes(self.take(8)?.try_into().unwrap()))
    }
    fn skip(&mut self, n: usize) -> Result<()> {
        self.take(n).map(|_| ())
    }
    fn fstring(&mut self) -> Result<String> {
        let len = self.i32()?;
        if len == 0 {
            return Ok(String::new());
        }
        if len > 0 {
            let b = self.take(len as usize)?;
            Ok(String::from_utf8_lossy(&b[..b.len() - 1]).into_owned())
        } else {
            let n = (-len) as usize;
            let b = self.take(n * 2)?;
            let w: Vec<u16> = b.chunks(2).map(|c| u16::from_le_bytes([c[0], c[1]])).collect();
            Ok(String::from_utf16_lossy(&w[..n - 1]))
        }
    }
}

pub struct Export {
    pub name: String,
    pub class_name: String,
    serial_offset: i64,
    serial_size: i64,
}

pub struct Package {
    pub names: Vec<String>,
    pub exports: Vec<Export>,
    total_header_size: i64,
}

/// One number found in an export: its property path (Export.Prop.Sub) and value.
#[derive(Clone, Debug)]
pub struct Found {
    pub export: String,
    pub path: String,
    pub leaf: String,
    pub value: f64,
}

const TAG: u32 = 0x9E2A83C1;
const PKG_FILTER_EDITOR_ONLY: u32 = 0x8000_0000;

impl Package {
    pub fn parse(uasset: &[u8]) -> Result<Package> {
        let mut c = Cursor::new(uasset, 0);
        if c.u32()? != TAG {
            return err("not a uasset (bad tag)");
        }
        let legacy = c.i32()?;
        if legacy != -4 {
            c.i32()?; // LegacyUE3Version
        }
        let ue4 = c.i32()?;
        if legacy <= -8 {
            c.i32()?; // FileVersionUE5
        }
        c.i32()?; // licensee
        if ue4 == 0 {
            return err("unversioned package (needs mappings)");
        }
        if legacy <= -2 {
            let n = c.i32()?;
            if !(0..10_000).contains(&n) {
                return err("bad custom version count");
            }
            c.skip(n as usize * 20)?;
        }
        let total_header_size = c.i32()? as i64;
        c.fstring()?; // FolderName
        let package_flags = c.u32()?;
        let name_count = c.i32()?;
        let name_offset = c.i32()?;
        if ue4 >= 516 && package_flags & PKG_FILTER_EDITOR_ONLY == 0 {
            c.fstring()?; // LocalizationId
        }
        if ue4 >= 459 {
            c.i32()?;
            c.i32()?;
        }
        let export_count = c.i32()?;
        let export_offset = c.i32()?;
        let _import_count = c.i32()?;
        let _import_offset = c.i32()?;
        let import_count = _import_count;
        let import_offset = _import_offset;

        let mut names = Vec::with_capacity(name_count.max(0) as usize);
        let mut nc = Cursor::new(uasset, name_offset as usize);
        for _ in 0..name_count {
            names.push(nc.fstring()?);
            if ue4 >= 504 {
                nc.u32()?;
            }
        }
        let name_of = |idx: i32, num: i32| -> String {
            let base = names.get(idx as usize).cloned().unwrap_or_else(|| format!("<name {idx}>"));
            if num > 0 { format!("{}_{}", base, num - 1) } else { base }
        };

        let mut imports = Vec::new();
        let mut ic = Cursor::new(uasset, import_offset as usize);
        for _ in 0..import_count {
            ic.skip(16)?; // ClassPackage, ClassName
            ic.i32()?; // outer
            let (i, n) = (ic.i32()?, ic.i32()?);
            imports.push(name_of(i, n));
        }

        let mut raw = Vec::new();
        let mut ec = Cursor::new(uasset, export_offset as usize);
        for _ in 0..export_count {
            let class_index = ec.i32()?;
            ec.i32()?; // super
            if ue4 >= 508 {
                ec.i32()?; // template
            }
            ec.i32()?; // outer
            let (i, n) = (ec.i32()?, ec.i32()?);
            ec.u32()?; // flags
            let (serial_size, serial_offset) = if ue4 >= 511 {
                (ec.i64()?, ec.i64()?)
            } else {
                (ec.i32()? as i64, ec.i32()? as i64)
            };
            ec.skip(12)?; // forced, not for client, not for server
            ec.skip(16)?; // package guid
            ec.u32()?; // package flags
            if ue4 >= 365 {
                ec.i32()?;
            }
            if ue4 >= 485 {
                ec.i32()?;
            }
            if ue4 >= 507 {
                ec.skip(20)?;
            }
            raw.push((class_index, name_of(i, n), serial_offset, serial_size));
        }
        let exports = raw
            .iter()
            .map(|(ci, name, off, size)| {
                let class_name = if *ci < 0 {
                    imports.get((-ci - 1) as usize).cloned().unwrap_or_default()
                } else if *ci > 0 {
                    raw.get((*ci - 1) as usize).map(|r| r.1.clone()).unwrap_or_default()
                } else {
                    "Class".to_string()
                };
                Export { name: name.clone(), class_name, serial_offset: *off, serial_size: *size }
            })
            .collect();
        Ok(Package { names, exports, total_header_size })
    }

    fn fname(&self, c: &mut Cursor) -> Result<String> {
        let idx = c.i32()?;
        let num = c.i32()?;
        match self.names.get(idx as usize) {
            Some(n) if num > 0 => Ok(format!("{}_{}", n, num - 1)),
            Some(n) => Ok(n.clone()),
            None => err(format!("bad name index {idx}")),
        }
    }

    /// Every number in every export's tagged properties. Exports that fail to parse are skipped and
    /// reported in `errors`.
    pub fn numbers(&self, uexp: &[u8], errors: &mut Vec<String>) -> Vec<Found> {
        let mut out = Vec::new();
        for e in &self.exports {
            if e.class_name.ends_with("GeneratedClass") || e.class_name == "Class" || e.class_name == "Function" {
                continue;
            }
            let start = (e.serial_offset - self.total_header_size) as usize;
            let end = start + e.serial_size.max(0) as usize;
            if end > uexp.len() {
                errors.push(format!("{}: export outside .uexp", e.name));
                continue;
            }
            let mut c = Cursor::new(&uexp[..end], start);
            if let Err(x) = self.read_props(&mut c, end, &e.name, "", &mut out, 0) {
                errors.push(format!("{}: {}", e.name, x));
            }
        }
        out
    }

    fn read_props(&self, c: &mut Cursor, end: usize, export: &str, prefix: &str, out: &mut Vec<Found>, depth: u32) -> Result<()> {
        if depth > 12 {
            return err("properties nested too deep");
        }
        loop {
            if c.pos >= end {
                return Ok(());
            }
            let name = self.fname(c)?;
            if name == "None" {
                return Ok(());
            }
            let ty = self.fname(c)?;
            let size = c.i32()?;
            let index = c.i32()?;
            if size < 0 {
                return err(format!("negative size for {name}"));
            }
            let mut struct_name = String::new();
            let mut inner = String::new();
            let mut bool_val = 0u8;
            match ty.as_str() {
                "StructProperty" => {
                    struct_name = self.fname(c)?;
                    c.skip(16)?;
                }
                "BoolProperty" => bool_val = c.u8()?,
                "ByteProperty" | "EnumProperty" => {
                    self.fname(c)?;
                }
                "ArrayProperty" | "SetProperty" => inner = self.fname(c)?,
                "MapProperty" => {
                    self.fname(c)?;
                    self.fname(c)?;
                }
                _ => {}
            }
            if c.u8()? != 0 {
                c.skip(16)?;
            }
            let value_start = c.pos;
            let value_end = value_start + size as usize;
            if value_end > end {
                return err(format!("{name} runs past the export"));
            }
            let label = if index > 0 { format!("{name}[{index}]") } else { name.clone() };
            let path = if prefix.is_empty() { label.clone() } else { format!("{prefix}.{label}") };
            let mut push = |v: f64| out.push(Found { export: export.to_string(), path: path.clone(), leaf: name.clone(), value: v });
            match ty.as_str() {
                "FloatProperty" if size == 4 => push(c.f32()? as f64),
                "DoubleProperty" if size == 8 => push(c.f64()?),
                "IntProperty" | "UInt32Property" if size == 4 => push(c.i32()? as f64),
                "Int64Property" if size == 8 => push(c.i64()? as f64),
                "ByteProperty" if size == 1 => push(c.u8()? as f64),
                "BoolProperty" => push(bool_val as f64),
                "StructProperty" if !is_binary_struct(&struct_name) => {
                    // Nested tagged struct; a struct we misjudge just gets skipped.
                    let mut sub = Cursor::new(&c.data[..value_end], value_start);
                    let _ = self.read_props(&mut sub, value_end, export, &path, out, depth + 1);
                }
                "ArrayProperty" if inner == "StructProperty" => {
                    let mut sub = Cursor::new(&c.data[..value_end], value_start);
                    let _ = self.read_struct_array(&mut sub, value_end, export, &path, out, depth);
                }
                _ => {}
            }
            c.pos = value_end;
        }
    }

    fn read_struct_array(&self, c: &mut Cursor, end: usize, export: &str, path: &str, out: &mut Vec<Found>, depth: u32) -> Result<()> {
        let count = c.i32()?;
        self.fname(c)?; // inner tag name
        self.fname(c)?; // StructProperty
        c.i32()?;
        c.i32()?;
        let struct_name = self.fname(c)?;
        c.skip(16)?;
        if c.u8()? != 0 {
            c.skip(16)?;
        }
        if is_binary_struct(&struct_name) {
            return Ok(());
        }
        for i in 0..count.clamp(0, 256) {
            self.read_props(c, end, export, &format!("{path}[{i}]"), out, depth + 1)?;
        }
        Ok(())
    }
}

fn is_binary_struct(name: &str) -> bool {
    matches!(
        name,
        "Vector" | "Vector2D" | "Vector4" | "Rotator" | "Quat" | "Color" | "LinearColor" | "Guid" | "IntPoint"
            | "IntVector" | "Box" | "Box2D" | "DateTime" | "Timespan" | "SoftObjectPath" | "SoftClassPath"
            | "GameplayTagContainer" | "FrameNumber" | "PerPlatformFloat" | "PerPlatformInt" | "NavAgentSelector"
            | "RichCurveKey" | "Plane" | "Matrix" | "Transform" | "UniqueNetIdRepl" | "SkeletalMeshSamplingLODBuiltData"
            | "FontData" | "FontCharacter" | "MovieSceneFrameRange" | "SectionEvaluationDataTree" | "MovieSceneSegment"
    )
}

#[cfg(test)]
pub use tests::sample as test_sample;

#[cfg(test)]
mod tests {
    use super::*;

    fn fstr(s: &str) -> Vec<u8> {
        let mut v = ((s.len() + 1) as i32).to_le_bytes().to_vec();
        v.extend_from_slice(s.as_bytes());
        v.push(0);
        v
    }

    /// Builds a tiny UE4.27-style package: one CDO export with Damage (float), ClipSize (int) and a
    /// nested struct holding RateOfFire.
    pub fn sample() -> (Vec<u8>, Vec<u8>) {
        let names = ["None", "Damage", "FloatProperty", "ClipSize", "IntProperty", "Stats", "StructProperty",
            "WeaponStats", "RateOfFire", "Default__WPN_Test_C", "WPN_Test_C", "/Script/FSD", "Class", "Gun"];
        let ni = |s: &str| names.iter().position(|n| *n == s).unwrap() as i32;
        let fname = |s: &str| { let mut v = ni(s).to_le_bytes().to_vec(); v.extend_from_slice(&0i32.to_le_bytes()); v };

        let mut props = Vec::new();
        props.extend(fname("Damage")); props.extend(fname("FloatProperty"));
        props.extend(4i32.to_le_bytes()); props.extend(0i32.to_le_bytes()); props.push(0);
        props.extend(15.5f32.to_le_bytes());
        props.extend(fname("ClipSize")); props.extend(fname("IntProperty"));
        props.extend(4i32.to_le_bytes()); props.extend(0i32.to_le_bytes()); props.push(0);
        props.extend(30i32.to_le_bytes());
        let mut inner = Vec::new();
        inner.extend(fname("RateOfFire")); inner.extend(fname("FloatProperty"));
        inner.extend(4i32.to_le_bytes()); inner.extend(0i32.to_le_bytes()); inner.push(0);
        inner.extend(7.0f32.to_le_bytes());
        inner.extend(fname("None"));
        props.extend(fname("Stats")); props.extend(fname("StructProperty"));
        props.extend((inner.len() as i32).to_le_bytes()); props.extend(0i32.to_le_bytes());
        props.extend(fname("WeaponStats")); props.extend([0u8; 16]); props.push(0);
        props.extend(inner);
        props.extend(fname("None"));
        props.extend(0i32.to_le_bytes()); // object trailer

        let mut name_map = Vec::new();
        for n in names { name_map.extend(fstr(n)); name_map.extend(0u32.to_le_bytes()); }
        let mut import = Vec::new();
        import.extend(fname("/Script/FSD")); import.extend(fname("Class"));
        import.extend(0i32.to_le_bytes()); import.extend(fname("Gun"));

        let mut head = Vec::new();
        head.extend(TAG.to_le_bytes()); head.extend((-7i32).to_le_bytes()); head.extend(864i32.to_le_bytes());
        head.extend(522i32.to_le_bytes()); head.extend(0i32.to_le_bytes()); head.extend(0i32.to_le_bytes());
        let ths_pos = head.len(); head.extend(0i32.to_le_bytes());
        head.extend(fstr("None")); head.extend(PKG_FILTER_EDITOR_ONLY.to_le_bytes());
        head.extend((names.len() as i32).to_le_bytes()); let no_pos = head.len(); head.extend(0i32.to_le_bytes());
        head.extend(0i32.to_le_bytes()); head.extend(0i32.to_le_bytes());
        head.extend(1i32.to_le_bytes()); let eo_pos = head.len(); head.extend(0i32.to_le_bytes());
        head.extend(1i32.to_le_bytes()); let io_pos = head.len(); head.extend(0i32.to_le_bytes());
        let name_off = head.len(); head.extend(name_map);
        let imp_off = head.len(); head.extend(import);
        let exp_off = head.len();
        let total = exp_off + 104;
        let mut exp = Vec::new();
        exp.extend((-1i32).to_le_bytes()); exp.extend(0i32.to_le_bytes()); exp.extend(0i32.to_le_bytes()); exp.extend(0i32.to_le_bytes());
        exp.extend(fname("Default__WPN_Test_C")); exp.extend(0u32.to_le_bytes());
        exp.extend((props.len() as i64).to_le_bytes()); exp.extend((total as i64).to_le_bytes());
        exp.extend([0u8; 12]); exp.extend([0u8; 16]); exp.extend(0u32.to_le_bytes());
        exp.extend(0i32.to_le_bytes()); exp.extend(0i32.to_le_bytes()); exp.extend([0u8; 20]);
        head.extend(exp);
        head[ths_pos..ths_pos + 4].copy_from_slice(&(total as i32).to_le_bytes());
        head[no_pos..no_pos + 4].copy_from_slice(&(name_off as i32).to_le_bytes());
        head[eo_pos..eo_pos + 4].copy_from_slice(&(exp_off as i32).to_le_bytes());
        head[io_pos..io_pos + 4].copy_from_slice(&(imp_off as i32).to_le_bytes());
        (head, props)
    }

    #[test]
    fn reads_numbers_from_a_cdo() {
        let (uasset, uexp) = sample();
        let p = Package::parse(&uasset).unwrap();
        assert_eq!(p.exports.len(), 1);
        assert_eq!(p.exports[0].name, "Default__WPN_Test_C");
        assert_eq!(p.exports[0].class_name, "Gun");
        let mut errors = Vec::new();
        let f = p.numbers(&uexp, &mut errors);
        assert!(errors.is_empty(), "{errors:?}");
        let get = |leaf: &str| f.iter().find(|x| x.leaf == leaf).map(|x| x.value);
        assert_eq!(get("Damage"), Some(15.5));
        assert_eq!(get("ClipSize"), Some(30.0));
        assert_eq!(get("RateOfFire"), Some(7.0));
        assert_eq!(f.iter().find(|x| x.leaf == "RateOfFire").unwrap().path, "Stats.RateOfFire");
    }
}
