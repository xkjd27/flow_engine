//! flow_engine order 库的 schema 解码 / 编码。
//!
//! key 布局（见 engine/README.md、engine/lua/flow_order.lua、flow_sync.lua）：
//!
//! | key | value |
//! | --- | --- |
//! | `ord/<音码>\|<形码>` | `\t` 分隔的候选；候选 = 词 或 「词 完整音节」 |
//! | `ord/~recent` | `\t` 分隔的词，越靠前越新（上限 recent_max） |
//! | `ord/~secondary` | `\t` 分隔的 `码=文本`（文本空 = 取消默认次简） |
//! | `sbb/<码>` | 声笔简码覆盖的文本（没有这条 key = 用默认表） |
//! | `/db_name` … | Rime userdb 元数据（只读） |
//! | `fsync <TAB>…` | 旧版同步遗留记录，`\x1f` 分隔字段 + %XX 转义 |
//!
//! 形码字母到笔形的映射来自方案仓库 `layout.py` 的 `JD_B`：
//! 乛→a、丨→i、丶→o、㇐→v、丿→e（27C）或 u（27 / 键道6）。
//! 这里按 schema 里读到的 `shape_keys` 判断用哪个字母。

pub const ORDER_PREFIX: &str = "ord/";
pub const SHENGBI_PREFIX: &str = "sbb/";
pub const RECENT_KEY: &str = "ord/~recent";
pub const SECONDARY_KEY: &str = "ord/~secondary";
pub const LEGACY_PREFIX: &str = "fsync";

#[derive(Clone, PartialEq)]
pub struct Cand {
    pub word: String,
    /// 音码削减过的 pin 才有的「完整音节」注记（空 = 无）。
    pub syl: String,
}

#[derive(Clone)]
pub struct Pin {
    pub sound: String,
    pub shape: String,
    pub cands: Vec<Cand>,
    /// 加载时的 key（None = 新增条目）。
    pub orig_key: Option<String>,
    pub orig_cands: Vec<Cand>,
    pub deleted: bool,
}

impl Pin {
    pub fn key(&self) -> String {
        format!("{ORDER_PREFIX}{}|{}", self.sound, self.shape)
    }
    pub fn is_new(&self) -> bool {
        self.orig_key.is_none()
    }
    pub fn is_dirty(&self) -> bool {
        !self.deleted
            && (self.orig_key.as_deref() != Some(self.key().as_str()) || self.cands != self.orig_cands)
    }
    pub fn matches(&self, filter: &str) -> bool {
        self.sound.contains(filter)
            || self.shape.contains(filter)
            || self.cands.iter().any(|c| c.word.contains(filter))
    }
    /// 列表里的一行预览。
    pub fn preview(&self) -> String {
        let first = self
            .cands
            .first()
            .map(|c| c.word.as_str())
            .unwrap_or("（空）");
        let n = self.cands.len();
        if n > 1 {
            format!("{first}  +{}", n - 1)
        } else {
            first.to_string()
        }
    }
}

pub fn parse_cands(value: &str) -> Vec<Cand> {
    value
        .split('\t')
        .filter(|s| !s.is_empty())
        .map(|entry| match entry.split_once(' ') {
            Some((word, syl)) if !syl.is_empty() => Cand {
                word: word.to_string(),
                syl: syl.to_string(),
            },
            _ => Cand {
                word: entry.to_string(),
                syl: String::new(),
            },
        })
        .collect()
}

pub fn serialize_cands(cands: &[Cand]) -> String {
    cands
        .iter()
        .map(|c| {
            if c.syl.is_empty() {
                c.word.clone()
            } else {
                format!("{} {}", c.word, c.syl)
            }
        })
        .collect::<Vec<_>>()
        .join("\t")
}

fn parse_pairs(value: &str) -> Vec<(String, String)> {
    value
        .split('\t')
        .filter(|s| !s.is_empty())
        .filter_map(|entry| {
            let (code, text) = entry.split_once('=')?;
            Some((code.to_string(), text.to_string()))
        })
        .collect()
}

/// 次简表的编码：`码=文本`，按整串排序后 join（和 flow_order.serialize_secondary 一致）。
fn serialize_secondary(rows: &[(String, String)]) -> String {
    let mut parts: Vec<String> = rows.iter().map(|(c, t)| format!("{c}={t}")).collect();
    parts.sort();
    parts.join("\t")
}

/// 旧版同步记录（`fsync <TAB>…`），只读展示 + 清理。
#[derive(Clone)]
pub struct Legacy {
    pub key: String,
    pub version: String,
    pub kind: String,
    /// pin/unpin 是词，sbb/sec 是码。
    pub identity: String,
    pub args: Vec<String>,
    pub ts: String,
    pub user: String,
    pub seq: String,
    pub deleted: bool,
}

impl Legacy {
    pub fn parse(key: &str) -> Self {
        let rec = key.strip_prefix(LEGACY_PREFIX).unwrap_or(key);
        let rec = rec
            .strip_prefix(" \t")
            .or_else(|| rec.strip_prefix('\t'))
            .unwrap_or(rec);
        let fields: Vec<String> = rec.split('\u{1f}').map(unescape).collect();
        let version = fields.first().cloned().unwrap_or_default();
        let kind = fields.get(1).cloned().unwrap_or_default();
        let rest: Vec<String> = fields.iter().skip(2).cloned().collect();
        let (identity, args, ts, user, seq) = if rest.len() >= 4 {
            let n = rest.len();
            (
                rest[0].clone(),
                rest[1..n - 3].to_vec(),
                rest[n - 3].clone(),
                rest[n - 2].clone(),
                rest[n - 1].clone(),
            )
        } else {
            (
                rest.first().cloned().unwrap_or_default(),
                rest.get(1..).map(<[String]>::to_vec).unwrap_or_default(),
                String::new(),
                String::new(),
                String::new(),
            )
        };
        Self {
            key: key.to_string(),
            version,
            kind,
            identity,
            args,
            ts,
            user,
            seq,
            deleted: false,
        }
    }

    pub fn kind_label(&self) -> &str {
        match self.kind.as_str() {
            "pin" => "调序/造词",
            "unpin" => "取消调序",
            "sbb" => "声笔覆盖",
            "sbclear" => "清声笔",
            "sec" => "次简覆盖",
            "secclear" => "清次简",
            other => other,
        }
    }

    /// 毫秒时间戳 → 本地时间。
    pub fn ts_text(&self) -> String {
        let Ok(ms) = self.ts.parse::<i64>() else {
            return self.ts.clone();
        };
        let t = (ms / 1000) as libc::time_t;
        unsafe {
            let mut tm: libc::tm = std::mem::zeroed();
            if libc::localtime_r(&t, &mut tm).is_null() {
                return self.ts.clone();
            }
            format!(
                "{:04}-{:02}-{:02} {:02}:{:02}:{:02}",
                tm.tm_year + 1900,
                tm.tm_mon + 1,
                tm.tm_mday,
                tm.tm_hour,
                tm.tm_min,
                tm.tm_sec
            )
        }
    }
}

fn unescape(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' && i + 2 < b.len() && b[i + 1].is_ascii_hexdigit() && b[i + 2].is_ascii_hexdigit()
        {
            if let Ok(v) = u8::from_str_radix(&s[i + 1..i + 3], 16) {
                out.push(v);
                i += 3;
                continue;
            }
        }
        out.push(b[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// 整个库解码后的内容。
#[derive(Default)]
pub struct OrderDb {
    pub db_name: String,
    pub pins: Vec<Pin>,
    pub recent: Vec<String>,
    pub orig_recent: Vec<String>,
    pub secondary: Vec<(String, String)>,
    pub orig_secondary: Vec<(String, String)>,
    pub shengbi: Vec<(String, String)>,
    pub orig_shengbi: Vec<(String, String)>,
    pub legacy: Vec<Legacy>,
    pub meta: Vec<(String, String)>,
    /// 不认识、或带 tab 的损坏 key（flow_order 会在 load 时清掉带 tab 的）。
    pub unknown: Vec<(String, String)>,
}

pub struct Diff {
    pub puts: Vec<(String, String)>,
    pub dels: Vec<String>,
}

impl OrderDb {
    pub fn parse(rows: &[(String, String)]) -> Self {
        let mut db = Self::default();
        for (key, value) in rows {
            if key == RECENT_KEY {
                db.recent = split_words(value);
                db.orig_recent = db.recent.clone();
            } else if key == SECONDARY_KEY {
                db.secondary = parse_pairs(value);
                db.orig_secondary = db.secondary.clone();
            } else if let Some(rest) = key.strip_prefix(ORDER_PREFIX) {
                if rest.contains('\t') {
                    db.unknown.push((key.clone(), value.clone()));
                    continue;
                }
                let (sound, shape) = match rest.split_once('|') {
                    Some((s, h)) => (s.to_string(), h.to_string()),
                    None => (rest.to_string(), String::new()),
                };
                let cands = parse_cands(value);
                db.pins.push(Pin {
                    sound,
                    shape,
                    cands: cands.clone(),
                    orig_key: Some(key.clone()),
                    orig_cands: cands,
                    deleted: false,
                });
            } else if let Some(code) = key.strip_prefix(SHENGBI_PREFIX) {
                db.shengbi.push((code.to_string(), value.clone()));
            } else if key.starts_with(LEGACY_PREFIX) {
                db.legacy.push(Legacy::parse(key));
            } else if key.starts_with('/') {
                if key == "/db_name" {
                    db.db_name = value.clone();
                }
                db.meta.push((key.clone(), value.clone()));
            } else {
                db.unknown.push((key.clone(), value.clone()));
            }
        }
        db.orig_shengbi = db.shengbi.clone();
        db
    }

    /// 与加载时相比要写回的增删（一个 write batch）。
    pub fn diff(&self) -> Diff {
        let mut d = Diff { puts: Vec::new(), dels: Vec::new() };

        for p in &self.pins {
            if p.deleted {
                if let Some(orig) = &p.orig_key {
                    d.dels.push(orig.clone());
                }
                continue;
            }
            if p.cands.is_empty() {
                // 候选清空 = 删这条 pin（flow_order.save_key 的行为）
                if let Some(orig) = &p.orig_key {
                    d.dels.push(orig.clone());
                }
                continue;
            }
            if let Some(orig) = &p.orig_key
                && *orig != p.key()
            {
                d.dels.push(orig.clone());
            }
            if p.is_new() || p.is_dirty() {
                d.puts.push((p.key(), serialize_cands(&p.cands)));
            }
        }

        if self.recent != self.orig_recent {
            if self.recent.is_empty() {
                d.dels.push(RECENT_KEY.to_string());
            } else {
                d.puts.push((RECENT_KEY.to_string(), self.recent.join("\t")));
            }
        }

        if self.secondary != self.orig_secondary {
            if self.secondary.is_empty() {
                d.dels.push(SECONDARY_KEY.to_string());
            } else {
                d.puts
                    .push((SECONDARY_KEY.to_string(), serialize_secondary(&self.secondary)));
            }
        }

        let orig_codes: Vec<&str> = self.orig_shengbi.iter().map(|(c, _)| c.as_str()).collect();
        for (code, text) in &self.shengbi {
            let old = self.orig_shengbi.iter().find(|(c, _)| c == code);
            if old.map(|(_, t)| t) != Some(text) {
                d.puts.push((format!("{SHENGBI_PREFIX}{code}"), text.clone()));
            }
        }
        for code in orig_codes {
            if !self.shengbi.iter().any(|(c, _)| c == code) {
                d.dels.push(format!("{SHENGBI_PREFIX}{code}"));
            }
        }

        for l in &self.legacy {
            if l.deleted {
                d.dels.push(l.key.clone());
            }
        }

        d
    }

    pub fn dirty_count(&self) -> usize {
        self.pins
            .iter()
            .filter(|p| p.deleted || p.is_dirty())
            .count()
            + (self.recent != self.orig_recent) as usize
            + (self.secondary != self.orig_secondary) as usize
            + self
                .shengbi
                .iter()
                .filter(|(c, t)| {
                    self.orig_shengbi
                        .iter()
                        .find(|(oc, _)| oc == c)
                        .map(|(_, ot)| ot)
                        != Some(t)
                })
                .count()
            + self.orig_shengbi.iter().filter(|(c, _)| !self.shengbi.iter().any(|(nc, _)| nc == c)).count()
            + self.legacy.iter().filter(|l| l.deleted).count()
    }
}

fn split_words(value: &str) -> Vec<String> {
    value
        .split('\t')
        .filter(|s| !s.is_empty())
        .map(str::to_string)
        .collect()
}

/// 形码字母 → 笔形（layout.py 的 JD_B；撇在 27C 是 e，27/键道6 是 u）。
pub fn shape_stroke(letter: char, shape_keys: &str) -> Option<&'static str> {
    match letter {
        'a' => Some("乛"),
        'i' => Some("丨"),
        'o' => Some("丶"),
        'v' => Some("㇐"),
        'e' if shape_keys.contains('e') => Some("丿"),
        'u' if shape_keys.contains('u') => Some("丿"),
        _ => None,
    }
}

/// 形码串 → 笔形串（任一字母不认识就整体放弃）。
pub fn decode_shape(shape: &str, shape_keys: &str) -> Option<String> {
    if shape.is_empty() {
        return None;
    }
    let mut parts = Vec::new();
    for ch in shape.chars() {
        parts.push(shape_stroke(ch, shape_keys)?);
    }
    Some(parts.join(" "))
}

/// 从 schema / custom yaml 里读 `sound_keys` / `shape_keys`（后者优先，简单行扫描）。
pub fn load_key_sets(user_dir: &std::path::Path, db_name: &str) -> (String, String) {
    let dict = db_name.strip_suffix(".order").unwrap_or(db_name);
    let mut sound = String::new();
    let mut shape = String::new();
    for suffix in [".schema.yaml", ".custom.yaml"] {
        let path = user_dir.join(format!("{dict}{suffix}"));
        let Ok(text) = std::fs::read_to_string(&path) else {
            continue;
        };
        for line in text.lines() {
            if let Some(v) = yaml_value(line, "sound_keys") {
                sound = v;
            }
            if let Some(v) = yaml_value(line, "shape_keys") {
                shape = v;
            }
        }
    }
    (sound, shape)
}

fn yaml_value(line: &str, key: &str) -> Option<String> {
    let idx = line.find(key)?;
    let after = &line[idx + key.len()..];
    let colon = after.find(':')?;
    let token = after[colon + 1..].split_whitespace().next()?;
    Some(token.trim_matches('"').trim_matches('\'').to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rows() -> Vec<(String, String)> {
        vec![
            ("/db_name".into(), "demo.order".into()),
            ("fsync \tv1\u{1f}pin\u{1f}乞食\u{1f}qyuy|e\u{1f}1\u{1f}\u{1f}1791481967001\u{1f}user\u{1f}9".into(), "c=0".into()),
            ("ord/rt|".into(), "冉".into()),
            ("ord/whjy|eaaav".into(), "外纪\t外机 外机".into()),
            ("ord/~recent".into(), "类魂\t老叟戏顽童".into()),
            ("ord/~secondary".into(), "q=奇\tr=".into()),
            ("sbb/a".into(), "啊".into()),
        ]
    }

    #[test]
    fn parse_and_roundtrip() {
        let db = OrderDb::parse(&rows());
        assert_eq!(db.db_name, "demo.order");
        assert_eq!(db.pins.len(), 2);
        assert_eq!(db.pins[0].sound, "rt");
        assert_eq!(db.pins[0].shape, "");
        assert_eq!(db.pins[1].cands[1].syl, "外机");
        assert_eq!(db.recent, vec!["类魂", "老叟戏顽童"]);
        assert_eq!(db.secondary, vec![("q".into(), "奇".into()), ("r".into(), "".into())]);
        assert_eq!(db.shengbi, vec![("a".into(), "啊".into())]);
        assert_eq!(db.legacy.len(), 1);
        assert_eq!(db.legacy[0].kind, "pin");
        assert_eq!(db.legacy[0].identity, "乞食");
        assert_eq!(db.legacy[0].args, vec!["qyuy|e", "1", ""]);
        assert!(db.diff().puts.is_empty() && db.diff().dels.is_empty());
    }

    #[test]
    fn edits_become_batch() {
        let mut db = OrderDb::parse(&rows());
        db.pins[0].cands[0].word = "然".into();
        db.pins[1].deleted = true;
        db.recent.remove(0);
        db.shengbi[0].1 = "呵".into();
        db.legacy[0].deleted = true;
        let d = db.diff();
        assert!(d.puts.contains(&("ord/rt|".into(), "然".into())));
        assert!(d.puts.contains(&("ord/~recent".into(), "老叟戏顽童".into())));
        assert!(d.puts.contains(&("sbb/a".into(), "呵".into())));
        assert!(d.dels.contains(&"ord/whjy|eaaav".into()));
        assert!(d.dels.contains(&db.legacy[0].key));
        assert_eq!(db.dirty_count(), 5);
    }

    #[test]
    fn shape_decode() {
        assert_eq!(decode_shape("eaaav", "aeiov").unwrap(), "丿 乛 乛 乛 ㇐");
        assert_eq!(decode_shape("uav", "auiov").unwrap(), "丿 乛 ㇐");
        assert!(decode_shape("eaaav", "auiov").is_none());
    }
}
