# flow_engine

键道「流」方案共用的 lua 引擎，**键道27・流** 与 **键道27C・流** 挂同一份代码。

## 使用

作为 submodule 挂在方案仓库的 `engine/`。clone 方案仓库时带上 submodule 即可：

```sh
git clone --recurse-submodules https://github.com/xkjd27/rime_jd27c_flow
git clone --recurse-submodules https://github.com/xkjd27/rime_jd27_flow
```

不用 git 的话，把本仓库 `lua/*.lua` 拷到 `<user>/lua/`：`flow_env.lua`、`flow_codes.lua`、`flow_shengbi.lua`、`flow_filter.lua`、`flow_shape.lua`、`flow_order.lua`、`flow_create.lua`、`flow_shapes.lua`、`flow_secondary.lua`、`flow_sync.lua`。

生成码表（在方案仓库根目录）：`python3 engine/tools/build_flow_dict.py --layout layout.py`。

## 配置与数据文件

| 键 / 文件 | 作用 |
| --- | --- |
| `flow_engine/sound_keys` | 声母键，如 `bcdfghjklmnpqrstuwxyz;` |
| `flow_engine/shape_keys` | 笔形键，如 `aeiov` |
| `flow_engine/bindings/promote` | 上调键：正常模式调序，造词入库，声笔调整设 sb（默认「-」） |
| `flow_engine/bindings/demote` | 降档键：正常模式降档，造词删除，声笔调整设 sbb（默认「=」） |
| `flow_engine/bindings/prev_page` | 上一页键（不写就不由引擎管，交给方案自己的 key_binder） |
| `flow_engine/bindings/next_page` | 下一页键（同上） |
| `flow_engine/page_edge` | 翻页到头（第 1 页再往前 / 最后一页再往后）：`ignore` 吞掉（默认）/ `topup` 顶屏（当前内容上屏，按键继续 → 顺带出标点候选）/ `pass` 交给后面的处理器 |
| `punctuator/<full_shape\|half_shape>/;;` | 声母键里的标点连按两个（`;;`）给的候选：写法同其它标点（字符串 / 列表全部给出来 / `{commit:}` / `{pair:}`，只取候选、不自动上屏），全角 / 半角各一份；不写就不插 |
| `flow_order/backend` | 调序库后端：`leveldb`（默认）/ `txt` |
| `flow_order/name` | 调序库名，默认 `<词库>.order`（如 `xkjd27c_flow.ice.order`） |
| `flow_order/recent_max` | 最近造词列表上限 |
| `flow_order/sync` | 用户数据跨机同步开关（默认开；`false` 时完全不写同步记录） |
| `flow_hint` | 候选提示总开关 |
| `flow_hint/shape` | 笔形提示 |
| `flow_hint/topup` | 顶功提示（⛔️） |
| `flow_secondary` | 次简开关 |
| `<词库>.danzi.dict.yaml` | 单字码与权重 |
| `<词库>.shengbi.dict.yaml` | 声笔简码默认表（sb / sbb；用户覆盖在 flow_order 的 `sbb/<码>`） |
| `<词库>.shape.dict.yaml` | 形码表 |
| `<词库>.shape.txt` | 笔形筛选与提示 |
| `<词库>.secondary.yaml` | 次简默认值 |

`<词库>` 是 `translator/dictionary` 去掉变体后缀的名字（如 `xkjd27c_flow.ice` → `xkjd27c_flow`）；数据文件随方案仓库一起发，在用户目录、共享目录查找。

## 同步（跨机）

调序 pin、声笔简码覆盖、次简覆盖会跨机器同步。实现和全部细节见
`lua/flow_sync.lua` 的文件头，要点：

- 每个方案在用户目录维护一个自有文本文件 `<order 库名>.sync.txt`
  （如 `xkjd27c_flow.order.sync.txt`）：内容 = 每个身份一条当前状态
  （含墓碑），全量重写 + 原子替换，**不随编辑次数增长**；
- Rime 部署/同步时 `backup_config_files` 会把它拷到
  `<sync_dir>/<installation_id>/`；load 时引擎扫 `<sync_dir>/*/` 下的同名
  文件合并。每台机器只写自己的文件，**远端文件只读**（不会和云盘/别的
  机器抢写）；
- 不走 Rime 的 userdb 通道：userdb 快照的 key 必须是「码<TAB>词」、value
  会被重写成权重，合并又没有删除语义，历史记录会永久留在快照并集里；
  想清理就得改别人的快照文件（会撞云同步）。自有文件没有这些约束；
- 每个身份（pin 看词、sbb/次简看码）取时间最新的记录；删除用墓碑
  （`unpin` / `sbclear` / `secclear`），否则别的机器上旧记录会复活；
- 第一次 load 会把私有状态里有、但还没记录的身份补成记录（bootstrap），
  所以升级后第一次同步就能把老数据带出去；
- 时间戳用 `os.time` + 单调毫秒补精度（`rime_api.get_time_ms` 是开机毫秒，
  跨机不可比），版本 = `(时间, 序号)`；跨机同毫秒同序号的极小概率情况按记录
  内容排序兜底（确定性），两台机器系统时间差太大时结果可能不符合直觉；
- `flow_order/sync: false` 可关掉；leveldb / txt 后端都能用同步。

## 测试

- `lua tools/smoke.lua <A数据目录> <A词库> <A_schema_id> <A声母键> <A笔形键>
  <B数据目录> <B词库> <B_schema_id> <B声母键> <B笔形键>`：纯 Lua 冒烟测试
  （不需要 librime），验证两个方案共用一个 Lua state 时数据/缓存互不串。
- `luajit tools/test_sync.lua`（或 `lua`）：同步逻辑单元 + 多机模拟测试，
  用假 LevelDb 跑真实引擎，同步走真实文件（模拟 `backup_config_files` 把
  本地 `.sync.txt` 拷进 sync 目录），68 项检查，不需要 librime。
- `tools/sync_e2e.sh`：真实 librime 端到端测试（两台机器 A/B 共享 sync_dir，
  真的调 `RimeSyncUserData`），覆盖文件传输、pin/次简同步、冲突、墓碑、
  坏行、幂等、有界、bootstrap，30 项检查；编译 probe 和准备测试目录见
  脚本头部注释。

## 许可

GPL-3.0，见 `LICENSE`。
