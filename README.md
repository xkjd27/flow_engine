# flow_engine_lua

键道「流」方案共用的 lua 引擎，**键道27・流** 与 **键道27C・流** 挂同一份代码。

## 使用

作为 submodule 挂在方案仓库的 `rime/lua`。clone 方案仓库时带上 submodule 即可：

```sh
git clone --recurse-submodules https://github.com/xkjd27/rime_jd27c_flow
git clone --recurse-submodules https://github.com/xkjd27/rime_jd27_flow
```

不用 git 的话，把本仓库根目录的 `*.lua` 拷到 `<user>/lua/`：`flow_env.lua`、`flow_codes.lua`、`flow_filter.lua`、`flow_shape.lua`、`flow_order.lua`、`flow_create.lua`、`flow_shapes.lua`、`flow_secondary.lua`。

## 配置与数据文件

| 键 / 文件 | 作用 |
| --- | --- |
| `flow_engine/sound_keys` | 声母键，如 `bcdfghjklmnpqrstuwxyz;` |
| `flow_engine/shape_keys` | 笔形键，如 `aeiov` |
| `flow_order/backend` | 调序库后端：`leveldb`（默认）/ `txt` |
| `flow_order/name` | 调序库名，如 `xkjd27c_flow.order` |
| `flow_order/recent_max` | 最近造词列表上限 |
| `flow_hint` | 候选提示总开关 |
| `flow_hint/shape` | 笔形提示 |
| `flow_hint/topup` | 顶功提示（⛔️） |
| `flow_secondary` | 次简开关 |
| `<词库>.danzi.dict.yaml` | 单字码与权重 |
| `<词库>.shape.dict.yaml` | 形码表 |
| `<词库>.shape.txt` | 笔形筛选与提示 |
| `<词库>.secondary.yaml` | 次简默认值 |

`<词库>` 是 `translator/dictionary` 去掉变体后缀的名字（如 `xkjd27c_flow.ice` → `xkjd27c_flow`）；数据文件随方案仓库一起发，在用户目录、共享目录查找。

## 许可

GPL-3.0，见 `LICENSE`。
