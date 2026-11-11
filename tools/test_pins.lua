-- flow_engine 调码边界 / 旧数据清理测试（不依赖 librime）
--
-- 背景：旧版引擎在声笔码形（一声母键 + 笔形键）下按 - / = 会把声笔候选 pin 到
-- 1 键音码上（`ha` 按 - → ord/h| = 还没），单键、双键就会冒出不该出现在那个
-- 权重的词；而 leveldb 和同步文件都会把这批记录一直留着（重启、升级、换机器
-- 都还在）。后来加了「声笔码形禁用 - / =」（flow_shengbi.code_form），但已经
-- 写进库里的记录没人清。这个测试验证三件事：
--   1. flow_codes.sound_ok 的边界：单字可以缩到一简，多字词只能待在自己的
--      方案码上，纯笔码不判断；
--   2. load 时把越界的 pin 清掉（leveldb / txt 两种后端），合法的 pin 不动；
--   3. 清理会写 unpin 墓碑，所以下次 load 不会被同步文件里的坏记录复活，
--      而且没有越界记录时不再写文件（幂等）。
--
-- 用法：lua tools/test_pins.lua [engine_lua_dir]

local here = (debug.getinfo(1, "S").source or ""):match("^@(.*/)") or "./"
local ENGINE = (arg and arg[1]) or os.getenv("FLOW_ENGINE_LUA")
    or (here .. "../lua")
package.path = ENGINE .. "/?.lua;" .. package.path

local checks, failures = 0, 0
local function ok(cond, msg)
    checks = checks + 1
    if not cond then
        failures = failures + 1
        print("  FAIL: " .. msg)
    end
end

local function eq(got, want, msg)
    ok(got == want, string.format("%s（got=%s want=%s）", msg,
                                  tostring(got), tostring(want)))
end

-- ---------- stub：log ----------
local logs = {}
_G.log = {
    info = function(s) logs[#logs + 1] = "I " .. tostring(s) end,
    warning = function(s) logs[#logs + 1] = "W " .. tostring(s) end,
    error = function(s) logs[#logs + 1] = "E " .. tostring(s) end,
}

-- ---------- stub：假 LevelDb（按 user_dir + 名字分库） ----------
_G.__stores = {}
_G.__open_dbs = {}

local function store_of(dir, name)
    local key = dir .. "/" .. name .. ".userdb"
    local s = _G.__stores[key]
    if not s then
        s = { kv = {}, key = key }
        _G.__stores[key] = s
    end
    return s
end

_G.LevelDb = function(name)
    local dir = _G.rime_api and _G.rime_api.get_user_data_dir
        and _G.rime_api.get_user_data_dir() or "."
    local store = store_of(dir, name)
    local db = { _store = store, _name = name, _loaded = false }
    function db:loaded() return self._loaded end
    function db:open()
        if _G.__open_dbs[store.key] then
            return false
        end
        _G.__open_dbs[store.key] = true
        self._loaded = true
        return true
    end
    function db:close()
        _G.__open_dbs[store.key] = nil
        self._loaded = false
        return true
    end
    function db:update(k, v)
        if not self._loaded then return false end
        _G.__updates = (_G.__updates or 0) + 1
        self._store.kv[k] = v or ""
        return true
    end
    function db:erase(k)
        if not self._loaded then return false end
        self._store.kv[k] = nil
        return true
    end
    function db:fetch(k) return self._store.kv[k] end
    function db:query(prefix)
        if not self._loaded then return nil end
        local keys = {}
        for k in pairs(self._store.kv) do
            if k:sub(1, #prefix) == prefix then
                keys[#keys + 1] = k
            end
        end
        table.sort(keys)
        local i = 0
        return {
            iter = function()
                return function()
                    i = i + 1
                    local k = keys[i]
                    if not k then return nil end
                    return k, self._store.kv[k]
                end
            end,
        }
    end
    return db
end

os.time = function() return _G.__wall or 1000 end

-- ---------- 测试数据 ----------
local ROOT = "/tmp/flow_pins_test"
local DICT = "testdict"
local SOUND = "bcdfghjklmnpqrstuwxyz;"
local SHAPE = "aeiov"

local DANZI = [[
# 测试用单字表（格式同 <词库>.danzi.dict.yaml）
---
name: testdict.danzi
version: "1"
...
我	wo	100
我	w	60
们	mk	100
你	ni	100
好	hz	100
和	h	100
和	hf	90
还	hc	100
没	mo	100
]]

-- 形码表（<词库>.shape.txt，值是笔形键串）
local SHAPES = [[
# char<TAB>shape
我	aae
们	eoi
你	ae
好	aeai
和	eo
还	vio
没	ivov
]]

local function write_file(path, text)
    local f = io.open(path, "w")
    if not f then return false end
    f:write(text or "")
    f:close()
    return true
end

local function read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local text = f:read("a")
    f:close()
    return text
end

local function fresh_dir()
    os.execute("rm -rf " .. ROOT)
    os.execute("mkdir -p " .. ROOT)
    _G.__stores = {}          -- 假 LevelDb 的仓库也要清（不然上一节的 pin 留到下一节）
    _G.__open_dbs = {}
    write_file(ROOT .. "/" .. DICT .. ".danzi.dict.yaml", DANZI)
    write_file(ROOT .. "/" .. DICT .. ".shape.txt", SHAPES)
end

-- ---------- 引擎装载 ----------
local flow_env = require("flow_env")
local codes = require("flow_codes")
local order = require("flow_order")
local flow_sync = require("flow_sync")
local flow_shapes = require("flow_shapes")
local shape_filter = require("flow_shape")   -- 只用 _place（挤走逻辑）

local n_flow = 0
local function load(opts)
    opts = opts or {}
    n_flow = n_flow + 1
    local dir = opts.dir or ROOT
    _G.rime_api = {
        get_user_data_dir = function() return dir end,
        get_shared_data_dir = function() return nil end,
        get_sync_dir = function() return opts.sync_dir end,
        get_time_ms = function() return 0 end,
    }
    local backend = opts.backend
    local config = {
        get_string = function(_, k)
            if k == "translator/dictionary" then return DICT end
            if k == "schema/schema_id" then return "testpins" end
            if k == "flow_engine/sound_keys" then return SOUND end
            if k == "flow_engine/shape_keys" then return SHAPE end
            if k == "flow_order/backend" then return backend end
            if k == "flow_order/name" then return DICT .. ".order" end
            return nil
        end,
        get_bool = function(_, k)
            if k == "flow_order/sync" then return opts.sync end
            return nil
        end,
        get_int = function() return nil end,
    }
    local env = {
        engine = {
            schema = { schema_id = "testpins", config = config },
            context = {},
        },
        name_space = "testpins",
    }
    local flow = flow_env.attach(env)
    order.init(flow)
    _G.__last_env = env
    return flow, env
end

local function unload(flow, env)
    order.close(flow)
    flow_env.release(env or _G.__last_env)
end

local function order_path() return ROOT .. "/" .. DICT .. ".order.txt" end
local function sync_path() return ROOT .. "/" .. DICT .. ".order.sync.txt" end
local function kv() return store_of(ROOT, DICT .. ".order").kv end

-- 越界 / 合法的 pin（同一份数据，两种后端都用）
-- `h|` 是混的：改版后单字一简（好 hz）和旧版声笔调频留下的词（还没）共用一个 key。
local SETUP = {
    { key = "wo|", value = "我们" },      -- 词挂在 2 键音码上（旧版声笔 - 的产物）
    { key = "w|a", value = "我们" },      -- 词挂在 1 键音码 + 1 笔上
    { key = "h|", value = "好 hz\t还没" },
    { key = "womk|", value = "我们" },    -- 词在自己的方案码上
    { key = "|", value = "好" },          -- 空音码
}

-- ---------- 1. sound_ok 边界 ----------
print("== 1. 调码边界：单字可缩、词不行、纯笔码不判断 ==")
fresh_dir()
local flow = load({ sync = false })
ok(codes.init(flow), "codes.init 失败")
ok(codes.sound_ok(flow, "好", "h"), "单字可以挂 1 键简码")
ok(codes.sound_ok(flow, "好", "hz"), "单字可以挂声韵")
ok(not codes.sound_ok(flow, "好", "hzab"), "单字不能挂比全码更长的音码")
ok(codes.sound_ok(flow, "我们", "womk"), "词可以挂自己的方案码")
ok(not codes.sound_ok(flow, "我们", "wo"), "词不能挂更短的音码")
ok(not codes.sound_ok(flow, "我们", "w"), "词不能挂 1 键音码")
ok(not codes.sound_ok(flow, "还没", "h"), "旧版声笔那种「词挂 1 键」判定为越界")
ok(codes.sound_ok(flow, "好", "a"), "纯笔码不判断")
ok(codes.sound_ok(flow, "查无此字", "h"), "没码表数据的候选不判断（别误伤）")
ok(not codes.sound_ok(flow, "好", ""), "空音码不合法")
unload(flow, {})

-- ---------- 2. leveldb：load 时清掉越界 pin ----------
local function check_pruned(flow, tag)
    eq(order.get(flow, "wo|"), nil, tag .. "：词挂在 2 键音码上的 pin 被清掉")
    eq(order.get(flow, "w|a"), nil, tag .. "：词挂在 1 键音码上的 pin 被清掉")
    local h = order.get(flow, "h|")
    ok(h ~= nil and #h == 1 and h[1] == "好",
       tag .. "：同一 key 里的越界 pin 被摘掉、单字一简保留")    eq(order.get_syllable(flow, "h|", "好"), "hz",
       tag .. "：单字一简的完整音节还在（= 还能还原）")
    local w = order.get(flow, "womk|")
    ok(w ~= nil and w[1] == "我们", tag .. "：词在自己的方案码上的 pin 保留")
end

print("== 2. leveldb 后端：越界 pin 被清掉，合法 pin 不动 ==")
fresh_dir()
do
    local k = kv()
    for _, e in ipairs(SETUP) do k["ord/" .. e.key] = e.value end
end
flow = load({ sync = false })
check_pruned(flow, "leveldb")
eq(kv()["ord/wo|"], nil, "leveldb：库里真的删掉了（不只是内存）")
eq(kv()["ord/|"], nil, "leveldb：空音码的 pin 也删掉")
eq(kv()["ord/womk|"], "我们", "leveldb：合法 pin 的库记录没动")
eq(kv()["ord/h|"], "好 hz", "leveldb：同一 key 只摘掉词、单字记录不变")
unload(flow, {})

-- 再 load 一次：幂等（没有越界记录就不写库）
local updates0 = _G.__updates or 0
flow = load({ sync = false })
check_pruned(flow, "leveldb 二次 load")
eq(_G.__updates or 0, updates0, "leveldb：没有越界记录时不再写库（幂等）")
unload(flow, {})

-- ---------- 3. 同步：坏记录被墓碑压掉、不会复活 ----------
print("== 3. 同步记录：被清掉的 pin 会写 unpin 墓碑，不会被复活 ==")
fresh_dir()
do
    local k = kv()
    k["ord/h|"] = "好 hz"                  -- 本地合法的单字一简
    k["ord/womk|"] = "我们"                -- 本地合法的词 pin
end
local SEP = string.char(31)
local function enc(s) return (tostring(s or ""):gsub("%%", "%%25")) end
local function rec(kind, identity, key, index, syl, ts, seq)
    return table.concat({ "v1", kind, enc(identity), enc(key), tostring(index or 1),
                          enc(syl or ""), tostring(ts), tostring(seq) }, SEP)
end
-- 同步文件里有旧版写下的、在 1~2 键音码上的 pin 记录（+ 一条合法的）
write_file(sync_path(), "# flow_engine sync v1\n" ..
    rec("pin", "还没", "h|", 1, "", 1000, 1) .. "\n" ..
    rec("pin", "我们", "wo|", 1, "", 1000, 2) .. "\n" ..
    rec("pin", "我们", "w|a", 1, "", 1000, 3) .. "\n" ..
    rec("pin", "我们", "womk|", 1, "", 1000, 4) .. "\n")
-- 统计同步文件被重写几次（write_atomic = tmp + rename）
_G.__renames = 0
local real_rename = os.rename
os.rename = function(a, b)
    _G.__renames = _G.__renames + 1
    return real_rename(a, b)
end
flow = load({})
os.rename = real_rename
check_pruned(flow, "同步")
ok(_G.__renames <= 2, "同步：清理只多出一次重写（reconcile 一次 + 清理一次，没逐条写）")
local text = read_file(sync_path()) or ""
local kinds = {}     -- identity -> kind（后写的盖前写的，和引擎一样取最新）
for line in text:gmatch("[^\n]+") do
    if line:sub(1, 1) ~= "#" then
        local f = {}
        for field in line:gmatch("[^" .. SEP .. "]+") do
            f[#f + 1] = field
        end
        if f[1] == "v1" and f[3] then kinds[f[3]] = f[2] end
    end
end
ok(text:find("unpin", 1, true) ~= nil, "同步：越界 pin 写了 unpin 墓碑")
eq(kinds[enc("还没")], "unpin", "同步：越界 pin 的 pin 记录被替换成墓碑")
eq(kinds[enc("我们")], "pin", "同步：合法的词 pin 记录留着（不会被误删）")
unload(flow, {})
-- 第二次 load：状态一致，文件不该再变
local before = read_file(sync_path())
flow = load({})
check_pruned(flow, "同步二次 load")
eq(read_file(sync_path()), before, "同步：二次 load 不改文件（幂等）")
unload(flow, {})

-- ---------- 4. txt 后端 ----------
print("== 4. txt 后端：同样清掉 ==")
fresh_dir()
do
    local lines = { "# key\t候选" }
    for _, e in ipairs(SETUP) do lines[#lines + 1] = e.key .. "\t" .. e.value end
    write_file(order_path(), table.concat(lines, "\n") .. "\n")
end
flow = load({ sync = false, backend = "txt" })
check_pruned(flow, "txt")
local txt = read_file(order_path()) or ""
ok(txt:find("wo|", 1, true) == nil, "txt：越界 pin 从文件里删掉了")
ok(txt:find("womk|\t我们", 1, true) ~= nil, "txt：合法 pin 还在文件里")
ok(txt:find("h|\t好 hz", 1, true) ~= nil, "txt：单字一简还在文件里")
unload(flow, {})

-- ---------- 5. 挤走（place）：只沿自己的形码串顺延，不换音码 ----------
print("== 5. 调频挤走：被顶掉的候选只加形码，音码不变；越界记录不再被顺延 ==")
fresh_dir()
flow = load({ sync = false })
ok(flow_shapes.init(flow), "shapes.init 失败")
local place = shape_filter._place

-- 5a 单字：和 先在 h|，再拿 好 挤走它
place(flow, "和", "h", "", nil)
eq(order.get(flow, "h|")[1], "和", "挤走前：和 在 h|")
place(flow, "好", "h", "", nil)
eq(order.get(flow, "h|")[1], "好", "挤走后：好 占 h|")
local occ = order.get(flow, "h|e")
ok(occ ~= nil and occ[1] == "和",
   "被挤走的 和 落在 h|e（它自己的形码首键），不是别的音码")
ok(codes.sound_ok(flow, "和", "h"), "被挤走的 和 音码仍然合法（h 是 hz 的前缀）")
ok(order.get(flow, "h|a") == nil, "没有被写到别的形码级上")

-- 5b 词组：我们 先在 womk|，再拿 你们 挤走它
place(flow, "我们", "womk", "", nil)
place(flow, "你们", "womk", "", nil)
eq(order.get(flow, "womk|")[1], "你们", "挤走后：你们 占 womk|")
local w1 = order.get(flow, "womk|a")
ok(w1 ~= nil and w1[1] == "我们", "被挤走的 我们 落在 womk|a（形码首键 a）")
ok(codes.sound_ok(flow, "我们", "womk"), "被挤走的 我们 音码仍然是 womk（未变）")

-- 5c 库里本来就有越界记录：挤走时不能再顺延出一个新的越界 key
order.insert(flow, "h|", "我们", 1)     -- 词挂在 1 键音码上（旧版声笔调频的残留）
place(flow, "好", "h", "", nil)
eq(order.get(flow, "h|")[1], "好", "越界记录被顶掉后 好 占 h|")
eq(order.get(flow, "h|a"), nil,
   "越界的 我们 不会被顺延到 h|a（直接丢掉，不再写出新的脏 key）")
local survived = false
for _, k in ipairs({ "h|", "h|a", "h|e", "h|ae", "h|aeo" }) do
    for _, t in ipairs(order.get(flow, k) or {}) do
        if t == "我们" then survived = true end
    end
end
ok(not survived, "越界的 我们 没有在任何 h| 级别上留下新记录")
unload(flow, {})

os.execute("rm -rf " .. ROOT)

print("")
if failures == 0 then
    print(string.format("共 %d 项检查，全部通过", checks))
else
    print(string.format("共 %d 项检查，%d 项失败", checks, failures))
    os.exit(1)
end
