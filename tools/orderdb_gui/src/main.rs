//! flow_engine 的 order.userdb 管理工具（Rust + egui）。
//!
//! 按引擎的存储 schema 解码，而不是当 KV 浏览器：
//!   * 调序 pin（`ord/<音码>|<形码>`）—— 音码/形码分开编辑，形码解码成笔形；
//!   * 最近造词（`ord/~recent`）、次简（`ord/~secondary`）、声笔覆盖（`sbb/<码>`）；
//!   * 旧版同步遗留记录（`fsync …`）解码成字段，可一键清理；
//!   * Rime 元数据只读。
//!
//! rime 正在使用库时自动开只读快照；编辑要等 rime 退出后重开。
//! 打开期间本工具持有 LOCK（Fedora 的 leveldb 1.23 close 会断言，句柄不关），
//! 所以改完请关掉工具再启动 rime。

mod leveldb;
mod schema;

use eframe::egui;
use schema::OrderDb;
use std::path::{Path, PathBuf};
use std::sync::Arc;

const WARN: egui::Color32 = egui::Color32::from_rgb(230, 190, 90);
const BAD: egui::Color32 = egui::Color32::from_rgb(230, 120, 120);
const OK: egui::Color32 = egui::Color32::from_rgb(110, 200, 110);
const SNAP: egui::Color32 = egui::Color32::from_rgb(230, 170, 60);

#[derive(Clone, Copy, PartialEq, Eq)]
enum Tab {
    Pins,
    Recent,
    Secondary,
    Shengbi,
    Legacy,
    Meta,
}

impl Tab {
    const ALL: [Tab; 6] = [
        Tab::Pins,
        Tab::Recent,
        Tab::Secondary,
        Tab::Shengbi,
        Tab::Legacy,
        Tab::Meta,
    ];
    fn label(self) -> &'static str {
        match self {
            Tab::Pins => "调序",
            Tab::Recent => "最近造词",
            Tab::Secondary => "次简",
            Tab::Shengbi => "声笔",
            Tab::Legacy => "遗留记录",
            Tab::Meta => "元数据",
        }
    }
}

struct App {
    path_input: String,
    db: Option<leveldb::LevelDb>,
    snapshot: bool,
    data: OrderDb,
    tab: Tab,
    filter: String,
    selected_pin: Option<usize>,
    new_sound: String,
    new_shape: String,
    new_word: String,
    new_recent: String,
    new_code: String,
    new_text: String,
    sound_keys: String,
    shape_keys: String,
    status: String,
}

impl App {
    fn new(initial: Option<String>) -> Self {
        Self {
            path_input: initial.unwrap_or_else(|| default_db_path().to_string_lossy().into_owned()),
            db: None,
            snapshot: false,
            data: OrderDb::default(),
            tab: Tab::Pins,
            filter: String::new(),
            selected_pin: None,
            new_sound: String::new(),
            new_shape: String::new(),
            new_word: String::new(),
            new_recent: String::new(),
            new_code: String::new(),
            new_text: String::new(),
            sound_keys: String::new(),
            shape_keys: String::new(),
            status: "选库目录点「打开」；rime 正在使用时自动只读快照".into(),
        }
    }

    fn open(&mut self) {
        let path = PathBuf::from(self.path_input.trim());
        if !path.is_dir() {
            self.status = format!("目录不存在：{}", path.display());
            return;
        }
        match leveldb::open_any(&path) {
            Ok((db, snapshot)) => {
                self.db = Some(db);
                self.snapshot = snapshot;
                self.reload();
                self.status = if snapshot {
                    "只读快照：rime 正在使用该库。要编辑请先退出 fcitx5-rime，再「打开」".into()
                } else {
                    format!("已打开（可编辑）：{}。改完请关掉本工具再启动 rime", path.display())
                };
            }
            Err(e) => self.status = e,
        }
    }

    fn reload(&mut self) {
        let Some(db) = &self.db else { return };
        let rows = match db.scan() {
            Ok(rows) => rows,
            Err(e) => {
                self.status = e;
                return;
            }
        };
        self.data = OrderDb::parse(&rows);
        let user_dir = Path::new(self.path_input.trim())
            .parent()
            .map(Path::to_path_buf)
            .unwrap_or_default();
        let (sound, shape) = schema::load_key_sets(&user_dir, &self.data.db_name);
        self.sound_keys = sound;
        self.shape_keys = shape;
        self.selected_pin = (!self.data.pins.is_empty()).then_some(0);
        self.status = format!(
            "pin {} · 最近造词 {} · 次简 {} · 声笔 {} · 遗留 {} · 元数据 {}",
            self.data.pins.len(),
            self.data.recent.len(),
            self.data.secondary.len(),
            self.data.shengbi.len(),
            self.data.legacy.len(),
            self.data.meta.len(),
        );
    }

    fn save(&mut self) {
        let Some(db) = &self.db else { return };
        if self.snapshot {
            self.status = "只读快照不能保存".into();
            return;
        }
        let d = self.data.diff();
        if d.puts.is_empty() && d.dels.is_empty() {
            self.status = "没有要保存的修改".into();
            return;
        }
        let (np, nd) = (d.puts.len(), d.dels.len());
        match db.apply(&d.puts, &d.dels) {
            Ok(()) => {
                self.reload();
                self.status = format!("已保存：写 {np} 条、删 {nd} 条");
            }
            Err(e) => self.status = format!("保存失败：{e}"),
        }
    }

    fn add_pin(&mut self) {
        let sound = self.new_sound.trim().to_string();
        let shape = self.new_shape.trim().to_string();
        let word = self.new_word.trim().to_string();
        if sound.is_empty() {
            self.status = "音码不能为空".into();
            return;
        }
        let key = format!("{sound}|{shape}");
        if self.data.pins.iter().any(|p| !p.deleted && format!("{}|{}", p.sound, p.shape) == key) {
            self.status = format!("pin 已存在：{key}");
            return;
        }
        if word.is_empty() {
            self.status = "先给一个首选词".into();
            return;
        }
        self.data.pins.push(schema::Pin {
            sound,
            shape,
            cands: vec![schema::Cand { word, syl: String::new() }],
            orig_key: None,
            orig_cands: Vec::new(),
            deleted: false,
        });
        self.selected_pin = Some(self.data.pins.len() - 1);
        self.new_sound.clear();
        self.new_shape.clear();
        self.new_word.clear();
        self.status = "已加入，点「保存」写库".into();
    }

    fn add_recent(&mut self) {
        let word = self.new_recent.trim().to_string();
        if word.is_empty() {
            return;
        }
        self.data.recent.insert(0, word);
        self.new_recent.clear();
    }

    fn add_pair(&mut self, secondary: bool) {
        let code = self.new_code.trim().to_string();
        if code.is_empty() {
            self.status = "码不能为空".into();
            return;
        }
        let text = self.new_text.trim().to_string();
        let rows = if secondary {
            &mut self.data.secondary
        } else {
            &mut self.data.shengbi
        };
        if let Some(row) = rows.iter_mut().find(|(c, _)| *c == code) {
            row.1 = text;
        } else {
            rows.push((code, text));
        }
        self.new_code.clear();
        self.new_text.clear();
    }

    fn clear_legacy(&mut self) {
        let n = self.data.legacy.len();
        for l in &mut self.data.legacy {
            l.deleted = true;
        }
        self.status = format!("已标记 {n} 条遗留记录删除，点「保存」生效");
    }
}

fn load_first(paths: &[&str]) -> Option<Vec<u8>> {
    paths.iter().find_map(|p| std::fs::read(p).ok())
}

fn install_fonts(ctx: &egui::Context) {
    let mut fonts = egui::FontDefinitions::default();
    let sans = load_first(&[
        "/usr/local/share/fonts/s/SarasaGothicSC-Regular.ttf",
        "/usr/share/fonts/google-noto-cjk/NotoSansCJK-Regular.ttf",
        "/usr/share/fonts/wqy-zenhei/wqy-zenhei.ttf",
    ]);
    let mono = load_first(&[
        "/usr/local/share/fonts/s/SarasaFixedSC-Regular.ttf",
        "/usr/local/share/fonts/s/SarasaMonoSC-Regular.ttf",
    ]);
    if let Some(bytes) = sans {
        fonts
            .font_data
            .insert("cjk".into(), Arc::new(egui::FontData::from_owned(bytes)));
        for fam in [egui::FontFamily::Proportional, egui::FontFamily::Monospace] {
            fonts.families.entry(fam).or_default().push("cjk".into());
        }
    }
    if let Some(bytes) = mono {
        fonts
            .font_data
            .insert("cjk-mono".into(), Arc::new(egui::FontData::from_owned(bytes)));
        fonts
            .families
            .entry(egui::FontFamily::Monospace)
            .or_default()
            .insert(0, "cjk-mono".into());
    }
    ctx.set_fonts(fonts);
}

impl eframe::App for App {
    fn ui(&mut self, ui: &mut egui::Ui, _frame: &mut eframe::Frame) {
        let mut do_open = false;
        let mut do_reload = false;
        let mut do_save = false;
        let has_db = self.db.is_some();
        let snapshot = self.snapshot;
        let dirty = self.data.dirty_count();

        egui::Panel::top("top").show(ui, |ui| {
            ui.add_space(4.0);
            ui.horizontal(|ui| {
                ui.label("库目录");
                let w = (ui.available_width() - 150.0).max(220.0);
                ui.add_sized([w, 22.0], egui::TextEdit::singleline(&mut self.path_input));
                if ui.button("打开").clicked() {
                    do_open = true;
                }
                if ui.add_enabled(has_db, egui::Button::new("重载")).clicked() {
                    do_reload = true;
                }
            });
            ui.horizontal(|ui| {
                ui.label("预设");
                let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_default();
                for (name, file) in [
                    ("jd27c", "xkjd27c_flow.order.userdb"),
                    ("jd27", "xkjd27_flow.order.userdb"),
                    ("keytao", "keytao_flow.order.userdb"),
                ] {
                    if ui.small_button(name).clicked() {
                        self.path_input = home
                            .join(".local/share/fcitx5/rime")
                            .join(file)
                            .to_string_lossy()
                            .into_owned();
                    }
                }
                ui.separator();
                if snapshot {
                    ui.colored_label(SNAP, "只读快照");
                } else if has_db {
                    ui.colored_label(OK, "可编辑");
                } else {
                    ui.weak("未打开");
                }
                if has_db {
                    ui.label(format!("待保存 {dirty} 处"));
                }
                if ui
                    .add_enabled(has_db && !snapshot && dirty > 0, egui::Button::new("保存"))
                    .clicked()
                {
                    do_save = true;
                }
                if ui
                    .add_enabled(has_db && !snapshot, egui::Button::new("放弃修改"))
                    .clicked()
                {
                    do_reload = true;
                }
            });
            ui.add_space(2.0);
            ui.horizontal(|ui| {
                for t in Tab::ALL {
                    if ui.selectable_label(self.tab == t, t.label()).clicked() {
                        self.tab = t;
                    }
                }
            });
            ui.add_space(4.0);
        });

        egui::Panel::bottom("status").show(ui, |ui| {
            ui.add_space(2.0);
            ui.label(&self.status);
            ui.add_space(2.0);
        });

        match self.tab {
            Tab::Pins => self.pins_ui(ui),
            Tab::Recent => self.recent_ui(ui),
            Tab::Secondary => self.pairs_ui(ui, true),
            Tab::Shengbi => self.pairs_ui(ui, false),
            Tab::Legacy => self.legacy_ui(ui),
            Tab::Meta => self.meta_ui(ui),
        }

        if do_open {
            self.open();
        }
        if do_reload {
            self.reload();
        }
        if do_save {
            self.save();
        }
    }
}

impl App {
    fn pins_ui(&mut self, ui: &mut egui::Ui) {
        let mut add = false;
        let mut clicked = None;
        let can_edit = !self.snapshot;
        egui::Panel::left("pin_list")
            .resizable(true)
            .default_size(440.0)
            .show(ui, |ui| {
                ui.horizontal(|ui| {
                    ui.label("过滤");
                    ui.text_edit_singleline(&mut self.filter);
                });
                ui.separator();
                let filter = self.filter.trim().to_lowercase();
                egui::ScrollArea::vertical()
                    .auto_shrink([false, false])
                    .show(ui, |ui| {
                        ui.style_mut().wrap_mode = Some(egui::TextWrapMode::Truncate);
                        for (i, p) in self.data.pins.iter().enumerate() {
                            if !filter.is_empty() && !p.matches(&filter) {
                                continue;
                            }
                            let mut rt = egui::RichText::new(format!(
                                "{}|{}   {}",
                                p.sound,
                                p.shape,
                                p.preview()
                            ))
                            .monospace();
                            if p.deleted {
                                rt = rt.strikethrough().weak();
                            } else if p.is_dirty() {
                                rt = rt.color(WARN);
                            }
                            if ui.selectable_label(self.selected_pin == Some(i), rt).clicked() {
                                clicked = Some(i);
                            }
                        }
                    });
                ui.separator();
                ui.horizontal(|ui| {
                    ui.label("新增");
                    ui.add_sized(
                        [64.0, 20.0],
                        egui::TextEdit::singleline(&mut self.new_sound)
                            .hint_text("音码")
                            .font(egui::TextStyle::Monospace),
                    );
                    ui.label("|");
                    ui.add_sized(
                        [64.0, 20.0],
                        egui::TextEdit::singleline(&mut self.new_shape)
                            .hint_text("形码")
                            .font(egui::TextStyle::Monospace),
                    );
                    ui.add_sized(
                        [96.0, 20.0],
                        egui::TextEdit::singleline(&mut self.new_word).hint_text("首选词"),
                    );
                    if ui.add_enabled(can_edit, egui::Button::new("添加")).clicked() {
                        add = true;
                    }
                });
            });
        if let Some(i) = clicked {
            self.selected_pin = Some(i);
        }
        if add {
            self.add_pin();
        }

        let shape_keys = self.shape_keys.clone();
        let sound_keys = self.sound_keys.clone();
        egui::CentralPanel::default().show(ui, |ui| {
            let Some(i) = self.selected_pin.filter(|i| *i < self.data.pins.len()) else {
                ui.centered_and_justified(|ui| ui.weak("左侧选一条 pin，或先「打开」一个库"));
                return;
            };
            let p = &mut self.data.pins[i];
            ui.horizontal(|ui| {
                ui.label("音码");
                ui.add_enabled(
                    can_edit,
                    egui::TextEdit::singleline(&mut p.sound)
                        .font(egui::TextStyle::Monospace)
                        .desired_width(150.0),
                );
                ui.label("|");
                ui.label("形码");
                ui.add_enabled(
                    can_edit,
                    egui::TextEdit::singleline(&mut p.shape)
                        .font(egui::TextStyle::Monospace)
                        .desired_width(120.0),
                );
                ui.separator();
                if p.deleted {
                    ui.colored_label(BAD, "已标记删除");
                } else if p.is_dirty() {
                    ui.colored_label(WARN, "已修改（未保存）");
                }
            });
            let mut hints = Vec::new();
            if let Some(dec) = schema::decode_shape(&p.shape, &shape_keys) {
                hints.push(format!("形码 {} = {}", p.shape, dec));
            }
            if !sound_keys.is_empty() {
                hints.push(format!("声母键 {sound_keys}"));
            }
            if !hints.is_empty() {
                ui.weak(hints.join("　·　"));
            }
            ui.add_space(6.0);
            ui.label("候选（越靠前越优先；音节注记 = 音码削减过的 pin 的完整音节）");
            let mut up = None;
            let mut down = None;
            let mut remove = None;
            egui::ScrollArea::vertical()
                .auto_shrink([false, true])
                .max_height(380.0)
                .show(ui, |ui| {
                    egui::Grid::new("cands").striped(true).show(ui, |ui| {
                        for (j, c) in p.cands.iter_mut().enumerate() {
                            ui.label(format!("{}", j + 1));
                            ui.add_enabled(
                                can_edit,
                                egui::TextEdit::singleline(&mut c.word).desired_width(180.0),
                            );
                            ui.add_enabled(
                                can_edit,
                                egui::TextEdit::singleline(&mut c.syl)
                                    .hint_text("—")
                                    .desired_width(130.0),
                            );
                            ui.horizontal(|ui| {
                                if ui.small_button("↑").clicked() {
                                    up = Some(j);
                                }
                                if ui.small_button("↓").clicked() {
                                    down = Some(j);
                                }
                                if ui.small_button("×").clicked() {
                                    remove = Some(j);
                                }
                            });
                            ui.end_row();
                        }
                    });
                });
            if let Some(j) = up
                && j > 0
            {
                p.cands.swap(j, j - 1);
            }
            if let Some(j) = down
                && j + 1 < p.cands.len()
            {
                p.cands.swap(j, j + 1);
            }
            if let Some(j) = remove {
                p.cands.remove(j);
            }
            ui.add_space(4.0);
            let mut add_cand = false;
            let mut delete_pin = false;
            let mut restore_pin = false;
            ui.horizontal(|ui| {
                if ui.add_enabled(can_edit, egui::Button::new("+ 候选")).clicked() {
                    add_cand = true;
                }
                if p.deleted {
                    if ui.add_enabled(can_edit, egui::Button::new("恢复")).clicked() {
                        restore_pin = true;
                    }
                } else if ui.add_enabled(can_edit, egui::Button::new("删除该 pin")).clicked() {
                    delete_pin = true;
                }
                if let Some(orig) = &p.orig_key {
                    ui.weak(format!("原 key {orig}"));
                }
            });
            if add_cand {
                p.cands.push(schema::Cand {
                    word: String::new(),
                    syl: String::new(),
                });
            }
            if delete_pin {
                p.deleted = true;
            }
            if restore_pin {
                p.deleted = false;
            }
        });
    }

    fn recent_ui(&mut self, ui: &mut egui::Ui) {
        let mut add = false;
        let mut up = None;
        let mut down = None;
        let mut remove = None;
        let can_edit = !self.snapshot;
        egui::CentralPanel::default().show(ui, |ui| {
            ui.label("最近造词（越靠前越新；造词模式里按 ` 列出、= 删除）");
            ui.separator();
            egui::ScrollArea::vertical()
                .auto_shrink([false, false])
                .show(ui, |ui| {
                    egui::Grid::new("recent").striped(true).show(ui, |ui| {
                        for (j, w) in self.data.recent.iter_mut().enumerate() {
                            ui.label(format!("{}", j + 1));
                            ui.add_enabled(
                                can_edit,
                                egui::TextEdit::singleline(w).desired_width(220.0),
                            );
                            ui.horizontal(|ui| {
                                if ui.small_button("↑").clicked() {
                                    up = Some(j);
                                }
                                if ui.small_button("↓").clicked() {
                                    down = Some(j);
                                }
                                if ui.small_button("×").clicked() {
                                    remove = Some(j);
                                }
                            });
                            ui.end_row();
                        }
                    });
                });
            ui.separator();
            ui.horizontal(|ui| {
                ui.label("添加");
                ui.add_sized(
                    [200.0, 20.0],
                    egui::TextEdit::singleline(&mut self.new_recent).hint_text("词"),
                );
                if ui.add_enabled(can_edit, egui::Button::new("加到最前")).clicked() {
                    add = true;
                }
            });
        });
        if let Some(j) = up
            && j > 0
        {
            self.data.recent.swap(j, j - 1);
        }
        if let Some(j) = down
            && j + 1 < self.data.recent.len()
        {
            self.data.recent.swap(j, j + 1);
        }
        if let Some(j) = remove {
            self.data.recent.remove(j);
        }
        if add {
            self.add_recent();
        }
    }

    fn pairs_ui(&mut self, ui: &mut egui::Ui, secondary: bool) {
        let mut add = false;
        let mut remove = None;
        let can_edit = !self.snapshot;
        let (title, hint) = if secondary {
            (
                "次简覆盖（码 = 用户实际敲的键：音码 + 形码）",
                "文本空 = 取消默认次简；没这条 = 用默认表",
            )
        } else {
            ("声笔简码覆盖（码 = sb / sbb 的码）", "没这条 = 用默认表")
        };
        egui::CentralPanel::default().show(ui, |ui| {
            ui.label(title);
            ui.weak(hint);
            ui.separator();
            let rows = if secondary {
                &mut self.data.secondary
            } else {
                &mut self.data.shengbi
            };
            egui::ScrollArea::vertical()
                .auto_shrink([false, false])
                .show(ui, |ui| {
                    egui::Grid::new("pairs").striped(true).show(ui, |ui| {
                        for (j, (code, text)) in rows.iter_mut().enumerate() {
                            ui.add_enabled(
                                can_edit,
                                egui::TextEdit::singleline(code)
                                    .font(egui::TextStyle::Monospace)
                                    .desired_width(90.0),
                            );
                            ui.add_enabled(
                                can_edit,
                                egui::TextEdit::singleline(text).desired_width(220.0),
                            );
                            if ui.small_button("×").clicked() {
                                remove = Some(j);
                            }
                            ui.end_row();
                        }
                    });
                });
            ui.separator();
            ui.horizontal(|ui| {
                ui.label("添加");
                ui.add_sized(
                    [90.0, 20.0],
                    egui::TextEdit::singleline(&mut self.new_code)
                        .hint_text("码")
                        .font(egui::TextStyle::Monospace),
                );
                ui.add_sized(
                    [200.0, 20.0],
                    egui::TextEdit::singleline(&mut self.new_text).hint_text("文本"),
                );
                if ui.add_enabled(can_edit, egui::Button::new("添加")).clicked() {
                    add = true;
                }
            });
        });
        if let Some(j) = remove {
            if secondary {
                self.data.secondary.remove(j);
            } else {
                self.data.shengbi.remove(j);
            }
        }
        if add {
            self.add_pair(secondary);
        }
    }

    fn legacy_ui(&mut self, ui: &mut egui::Ui) {
        let mut cleanup = false;
        let can_edit = !self.snapshot;
        egui::CentralPanel::default().show(ui, |ui| {
            ui.horizontal(|ui| {
                ui.label(format!(
                    "旧版同步遗留记录（{} 条）—— 现在同步走 <order>.sync.txt，这些可以清掉",
                    self.data.legacy.len()
                ));
                if ui
                    .add_enabled(
                        can_edit && !self.data.legacy.is_empty(),
                        egui::Button::new("全部标记删除"),
                    )
                    .clicked()
                {
                    cleanup = true;
                }
            });
            ui.separator();
            egui::ScrollArea::vertical()
                .auto_shrink([false, false])
                .show(ui, |ui| {
                    egui::Grid::new("legacy").striped(true).show(ui, |ui| {
                        for h in ["类型", "词 / 码", "参数", "时间", "用户", "序号", "删"] {
                            ui.strong(h);
                        }
                        ui.end_row();
                        for l in self.data.legacy.iter_mut() {
                            ui.label(l.kind_label())
                                .on_hover_text(format!("{} · 原始 key：{}", l.version, l.key));
                            ui.label(&l.identity);
                            ui.label(l.args.join(" · "));
                            ui.label(l.ts_text());
                            let user = &l.user;
                            ui.label(if user.len() > 8 { &user[..8] } else { user });
                            ui.label(&l.seq);
                            ui.add_enabled(can_edit, egui::Checkbox::new(&mut l.deleted, ""));
                            ui.end_row();
                        }
                    });
                });
        });
        if cleanup {
            self.clear_legacy();
        }
    }

    fn meta_ui(&mut self, ui: &mut egui::Ui) {
        egui::CentralPanel::default().show(ui, |ui| {
            ui.label("Rime userdb 元数据（只读）");
            ui.separator();
            egui::Grid::new("meta").striped(true).show(ui, |ui| {
                for (k, v) in &self.data.meta {
                    ui.monospace(k);
                    ui.monospace(v);
                    ui.end_row();
                }
            });
            if !self.data.unknown.is_empty() {
                ui.add_space(8.0);
                ui.label("其它 key（不认识 / 带 tab 的损坏 key，flow_order 会在 load 时清掉损坏的）");
                ui.separator();
                egui::Grid::new("unknown").striped(true).show(ui, |ui| {
                    for (k, v) in &self.data.unknown {
                        ui.monospace(k.escape_debug().to_string());
                        ui.monospace(v);
                        ui.end_row();
                    }
                });
            }
        });
    }
}

fn default_db_path() -> PathBuf {
    let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_default();
    home.join(".local/share/fcitx5/rime/xkjd27c_flow.order.userdb")
}

/// `--grep`：按 schema 解码后查数据（pin 音码/形码/候选、最近造词、次简、
/// 声笔、遗留记录、元数据），输出 `类型\t键\t解码值`。
fn cli_grep(pattern: &str, path: &Path) -> i32 {
    let (db, snap) = match leveldb::open_any(path) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("{e}");
            return 1;
        }
    };
    let rows = match db.scan() {
        Ok(r) => r,
        Err(e) => {
            eprintln!("{e}");
            return 1;
        }
    };
    let data = OrderDb::parse(&rows);
    let pat = pattern.to_lowercase();
    let hit = |s: &str| s.to_lowercase().contains(&pat);
    let mut n = 0;
    if snap {
        eprintln!("[只读快照] {}", path.display());
    }
    for p in &data.pins {
        if hit(&p.sound) || hit(&p.shape) || p.cands.iter().any(|c| hit(&c.word)) {
            let cands = p
                .cands
                .iter()
                .map(|c| {
                    if c.syl.is_empty() {
                        c.word.clone()
                    } else {
                        format!("{}({})", c.word, c.syl)
                    }
                })
                .collect::<Vec<_>>()
                .join(" / ");
            println!("pin\t{}|{}\t{}", p.sound, p.shape, cands);
            n += 1;
        }
    }
    for w in &data.recent {
        if hit(w) {
            println!("recent\t{w}");
            n += 1;
        }
    }
    for (c, t) in &data.secondary {
        if hit(c) || hit(t) {
            println!("secondary\t{c}={t}");
            n += 1;
        }
    }
    for (c, t) in &data.shengbi {
        if hit(c) || hit(t) {
            println!("shengbi\t{c}\t{t}");
            n += 1;
        }
    }
    for l in &data.legacy {
        if hit(&l.kind) || hit(&l.identity) {
            println!(
                "legacy\t{}\t{}\t{}\t{}",
                l.kind,
                l.identity,
                l.args.join(" "),
                l.ts_text()
            );
            n += 1;
        }
    }
    for (k, v) in data.meta.iter().chain(data.unknown.iter()) {
        if hit(k) || hit(v) {
            println!("meta\t{k}\t{v}");
            n += 1;
        }
    }
    eprintln!("[{n} 条匹配 · {}]", path.display());
    (n == 0) as i32
}

fn main() -> eframe::Result<()> {
    let args: Vec<String> = std::env::args().collect();
    match args.get(1).map(String::as_str) {
        Some("--dump") => {
            let path = args.get(2).map(PathBuf::from).unwrap_or_else(default_db_path);
            match leveldb::open_any(&path) {
                Ok((db, snap)) => match db.scan() {
                    Ok(rows) => {
                        if snap {
                            eprintln!("[只读快照]");
                        }
                        for (k, v) in rows {
                            println!("{k}\t{v}");
                        }
                    }
                    Err(e) => {
                        eprintln!("{e}");
                        std::process::exit(1);
                    }
                },
                Err(e) => {
                    eprintln!("{e}");
                    std::process::exit(1);
                }
            }
            return Ok(());
        }
        Some("--grep") => {
            let Some(pattern) = args.get(2) else {
                eprintln!("用法: flow-orderdb --grep <关键词> [库目录]");
                std::process::exit(2);
            };
            let path = args.get(3).map(PathBuf::from).unwrap_or_else(default_db_path);
            std::process::exit(cli_grep(pattern, &path));
        }
        Some("-h") | Some("--help") => {
            println!(
                "flow_engine order.userdb 管理工具\n\
                 \n\
                 用法:\n\
                 \x20 flow-orderdb [库目录]                  GUI（给目录则直接打开；rime 在跑自动只读快照）\n\
                 \x20 flow-orderdb --dump [库目录]           原始 KV（默认 jd27c 库）\n\
                 \x20 flow-orderdb --grep <关键词> [库目录]  按 schema 解码后查询"
            );
            return Ok(());
        }
        _ => {}
    }
    let initial = args.get(1).cloned();
    let auto_open = initial.is_some();
    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_inner_size([1200.0, 800.0])
            .with_min_inner_size([760.0, 480.0])
            .with_title("flow order.userdb 管理器"),
        ..Default::default()
    };
    eframe::run_native(
        "flow-orderdb",
        options,
        Box::new(move |cc| {
            install_fonts(&cc.egui_ctx);
            let mut app = App::new(initial);
            if auto_open {
                app.open();
            }
            Ok(Box::new(app))
        }),
    )
}
