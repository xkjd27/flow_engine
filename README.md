# flow_engine_lua

键道「流」方案的共享 lua 引擎 —— **键道27・流** 和 **键道27C・流** 两个方案挂同一份代码。

## 为什么单独一个仓库

一个 rime 进程只有一个 Lua state，`lua_filter@*flow_filter` 走的是标准 `require`，
模块表会被 `package.loaded` 缓存（librime-lua 不会在切方案时重载模块，只销毁/重建组件实例）。
所以**模块级变量会跨方案存活**：如果两个方案都装在一个 rime 用户目录里、在同一个进程里切换，
先初始化的那个方案的数据（反查表、单字权重、缓存、order 库）会被另一个方案顺手用掉。

实测（旧代码，同一个 Lua state 里先 27C 再切 27）：

```
先初始化 27C：实 = u，水饺 = ubjc
再初始化 27 ：实 = u，水饺 = ubjc     <- 27 的「实」应该是 e 开头
```

本仓库把每个方案的东西按 `schema_id` 分开存（见 `flow_env.lua`），方案之间的差异只走
**schema 配置**和**数据文件**，因此同一份代码可以同时服务两个方案而互不污染。

## 安装

作为 submodule 挂在方案仓库的 `rime/lua`（引擎文件直接放在仓库根，挂载后就是
`<user>/lua/*.lua`，正好是 `require` 的搜索路径）：

```sh
git submodule add https://github.com/xkjd27/flow_engine_lua rime/lua
```

不用 git 的话，把这几个 `*.lua` 直接拷进 `<user>/lua/` 也行。

引擎依赖 librime 部署时生成的 `build/<词库>.reverse.bin`（提示码的来源）+ 方案自带的
`<词库>.danzi.dict.yaml` / `<词库>.shape.txt` / `<词库>.secondary.yaml`，所以挂好之后要
跟着方案一起部署（方案仓库里那三个数据文件是随仓库发的，反查表由部署产生）。

## 引擎读什么

| 来源 | 键 / 文件 | 说明 |
| --- | --- | --- |
| schema | `translator/dictionary` | 词库名，例如 `xkjd27c_flow.ice` |
| schema | `flow_engine/sound_keys` | 声母键，例如 `bcdfghjklmnpqrstuwxyz;` |
| schema | `flow_engine/shape_keys` | 笔形键，例如 `aeiov` |
| schema | `flow_order/backend`、`flow_order/name`、`flow_order/recent_max` | 调序库（leveldb / txt） |
| schema | `flow_hint`、`flow_hint/shape`、`flow_hint/topup` | 提示与排序开关 |
| schema | `flow_secondary` | 次简总开关 |
| 数据（部署产物） | `build/<词库>.reverse.bin` | **码的唯一来源**：`flow_codes` 用 `ReverseDb` 打开它做「文字 → 码」；librime 部署时生成，删掉它就没提示码了 |
| 数据（方案自带） | `<词库>.danzi.dict.yaml` | 单字读音权重，只用来给同一个字的多个码排序（反查表只给码不给权重） |
| 数据（方案自带） | `<词库>.shape.txt` | 形码表（前 4 笔形，键位由 `shape_keys` 决定） |
| 数据（方案自带） | `<词库>.secondary.yaml` | 次简默认值（扁平「键: 值」）。不是 `.dict.yaml`、也不在 schema 里引用，所以 librime 不会拿它去编译词库 |

方案自带的三个数据文件按「词库全名 → 去掉变体后缀的基础名（`xkjd27c_flow.ice` →
`xkjd27c_flow`）」在**用户目录、共享目录**里依次查找。

**两套方案的全部差异就是 `sound_keys` / `shape_keys`（schema）+ 这三个数据文件**（反查表
是部署产物，由各自词库编译出来）。引擎里没有任何硬编码的方案名、键位或默认数据：
`flow_engine/*` 缺任何一项就不启用（组件 early return，只打一条 error），数据文件缺了
就没有对应的功能（默认次简为空、提示没有权重……）并打 warning。

## 文件

| 文件 | 作用 |
| --- | --- |
| `flow_env.lua` | 每方案上下文（`schema_id` → 字典名、键位表、缓存、order 库…）、数据文件查找、引用计数 |
| `flow_codes.lua` | 单字码/词组音码推导（提示用），反查表 + 单字表权重 |
| `flow_shapes.lua` | 形码数据与期望形码串 |
| `flow_filter.lua` | 整段过滤 + 形码筛选 + 自动前进 + 手动调序 + 提示排序 |
| `flow_shape.lua` | 形码键处理器、造词模式按键、Tab 次简、`-`/`=` 调序、顶功 |
| `flow_order.lua` | 调序/造词的存储（leveldb / txt） |
| `flow_create.lua` | 造词模式 |
| `flow_secondary.lua` | 次简表（默认值 + 用户学习） |

## 冒烟测试（不需要 librime）

用假的 `rime_api` / `ReverseDb` 把引擎跑起来，重点是验证两个方案放进**同一个 Lua state**
时各用各的数据：

```sh
lua tools/smoke.lua \
  ../rime_jd27c_flow/rime xkjd27c_flow.ice xkjd27c_flow "bcdfghjklmnpqrstuwxyz;" aeiov \
  ../rime_jd27_flow/rime  xkjd27_flow.ice  xkjd27_flow  "bcdefghjklmnpqrstwxyz;" auiov
```

期望（关键几行）：

```
    A 的 实 = u ｜ B 的 实 = e
    A 的 水饺 形码 = aeaov ｜ B = auaov
```

`u` / `e` 和 `ae...` / `au...` 分别来自两套方案自己的数据 —— 换回旧代码跑同一场景，
第二次初始化会返回 `u`（污染），见上面「为什么单独一个仓库」。

## 备注

* 组件的 `init(env)` / `fini(env)` 是配对的（librime-lua 只在组件析构时调 `fini`）：
  `flow_order` 按方案引用计数，计数归零才 `db:close()`，否则 `order.userdb` 的 LOCK
  会一直占到进程退出（schema 切换 / 引擎销毁都不释放）。
* 引擎不读写 `xkjd27*` 之类的字面量；新增方案只要补 `flow_engine/*` 和两个数据文件。
