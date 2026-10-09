# flow orderdb 管理器

flow_engine 的 `order.userdb` 查看 / 编辑工具（Rust + egui），按引擎的存储
schema 解码，不是 KV 浏览器。

## 构建

```sh
cd engine/tools/orderdb_gui
cargo build --release        # 产物 target/release/flow-orderdb
```

只依赖系统的 `libleveldb.so.1`（Fedora: `leveldb`），不需要 leveldb-devel。
渲染用 glow（OpenGL）；中文用系统 Sarasa / Noto CJK 字体。

## 用法

```sh
flow-orderdb [库目录]                  # GUI；给目录就直接打开
flow-orderdb --dump [库目录]           # 原始 KV（默认 jd27c 库）
flow-orderdb --grep <关键词> [库目录]  # 按 schema 解码后查询
```

GUI 六个页：调序（`ord/<音码>|<形码>`）、最近造词（`ord/~recent`）、次简
（`ord/~secondary`）、声笔（`sbb/<码>`）、遗留记录（旧版 `fsync …`，可一键清）、
元数据（Rime userdb key，只读）。音码 / 形码分开编辑，形码解码成笔形（映射
来自方案 `layout.py` 的 `JD_B`，按 schema 的 `shape_keys` 选 `e` / `u`）；
候选一行一个，音码削减过的带「词 完整音节」注记。改完点「保存」，一次
write batch 写回。

`--grep` 输出 `类型<TAB>键<TAB>解码值`，类型：`pin` / `recent` / `secondary` /
`shengbi` / `legacy` / `meta`。

## 和 rime 的关系

- rime 正在使用库时（LOCK 被占）自动拷一份到 `/tmp` 只读打开，要编辑先退出
  fcitx5-rime 再重新打开；
- 本工具打开库期间持有 LOCK（Fedora 的 leveldb 1.23 在 close 时会断言，
  句柄不关、随进程退出释放），所以改完请关掉工具再启动 rime；
- 库里的 pin 同时也在 `<order>.sync.txt` 里有一份记录（同步用），引擎 load
  时会按 sync 文件合并。直接用本工具删 pin / 改顺序，下一次 load 可能被 sync
  记录盖回来——要真正删掉，得同时处理 sync 文件（工具目前不管 sync 文件）。
