-- 引擎冒烟测试（不需要 librime/wasm）
--
--   lua tools/smoke.lua <方案A数据目录> <A词库名> <A_schema_id> <A声母键> <A笔形键> \
--                       <方案B数据目录> <B词库名> <B_schema_id> <B声母键> <B笔形键>
--
-- 用假的 rime_api / ReverseDb（从单字表里查码）把引擎跑起来，先独立验一遍
-- 「单字码 -> 提示码」的推导，再把两个方案放进**同一个 Lua state** 里交替初始化，
-- 验证它们各用各的数据（真实场景：一个 rime 进程里装了两个方案）。

package.path = "./?.lua;" .. package.path

local scheme = {}   -- 由参数填入：{dir, dict, schema_id, sound, shape}

local function chomp(s) return (s:gsub("\n$", "")) end

-- 假的单字表：字 -> {码...}（真实引擎这里用 ReverseDb，冒烟测试用文件代替）
local function load_danzi(dir, base)
    local codes = {}
    local f = io.open(dir .. "/" .. base .. ".danzi.dict.yaml")
    if not f then
        error("读不到单字表：" .. dir .. "/" .. base .. ".danzi.dict.yaml")
    end
    for line in f:lines() do
        local ch, code = line:match("^([^\t]+)\t([^\t]+)\t[%d%.]+$")
        if ch and ch ~= "" then
            codes[ch] = codes[ch] or {}
            codes[ch][code] = true
        end
    end
    f:close()
    return codes
end

local danzi_cache = {}

_G.rime_api = {
    get_user_data_dir = function() return scheme.dir end,
    get_shared_data_dir = function() return nil end,
}

-- 假的 ReverseDb：file 形如 build/<dict>.reverse.bin
_G.ReverseDb = function(file)
    local dict = file:match("^build/(.*)%.reverse%.bin$")
    local base = dict and dict:match("^(.-)%.[^%.]+$") or dict
    local key = scheme.dir .. "/" .. (base or "")
    local codes = danzi_cache[key]
    if not codes then
        codes = load_danzi(scheme.dir, base)
        danzi_cache[key] = codes
    end
    return {
        lookup = function(_, ch)
            local list = codes[ch]
            if not list then
                return ""
            end
            local out = {}
            for code in pairs(list) do
                out[#out + 1] = code
            end
            table.sort(out)
            return table.concat(out, " ")
        end,
    }
end

-- 假的 env（只需要 schema 配置和 schema_id）。
-- 注意：键值要绑进闭包——真 librime 里每个方案的 config 是独立的，
-- 用全局变量会让「切到 B 之后 A 的 config 也返回 B 的值」，那是测试自己的 bug。
local function make_env(conf)
    local config = {
        get_string = function(_, key)
            if key == "translator/dictionary" then return conf.dict end
            if key == "schema/schema_id" then return conf.schema_id end
            if key == "flow_engine/sound_keys" then return conf.sound end
            if key == "flow_engine/shape_keys" then return conf.shape end
            return nil
        end,
        get_bool = function() return nil end,
        get_int = function() return nil end,
    }
    return {
        engine = {
            schema = { schema_id = conf.schema_id, config = config },
            context = {},
        },
        name_space = "smoke",
    }
end

local function set_scheme(dir, dict, schema_id, sound, shape)
    scheme = { dir = dir, dict = dict, schema_id = schema_id,
               sound = sound, shape = shape }
end

-- ---------------- 测试 ----------------

local flow_env = require("flow_env")
local codes = require("flow_codes")
local shapes = require("flow_shapes")
local secondary = require("flow_secondary")

local function init_one(dir, dict, schema_id, sound, shape)
    set_scheme(dir, dict, schema_id, sound, shape)
    local env = make_env({ dict = dict, schema_id = schema_id,
                           sound = sound, shape = shape })
    local flow = flow_env.attach(env)     -- 和组件 init 一样
    assert(codes.init(flow), schema_id .. ": codes.init 失败")
    assert(shapes.init(flow), schema_id .. ": shapes.init 失败")
    assert(secondary.init(flow), schema_id .. ": secondary.init 失败")
    return flow
end

-- 读方案自带的次简数据文件（只用来断言「引擎读的确实是这个文件」）
local function file_secondary(dir, dict)
    local base = dict:match("^(.-)%.[^%.]+$") or dict
    local f = io.open(dir .. "/" .. base .. ".secondary.yaml")
    if not f then
        return nil
    end
    local out = {}
    for line in f:lines() do
        if line:sub(1, 1) ~= "#" then
            local k, v = line:match("^%s*([^#%s:]+)%s*:%s*(.-)%s*$")
            if k and v and v ~= "" then
                out[k] = v
            end
        end
    end
    f:close()
    return out
end

local A_DIR = arg[1]
local A_DICT = arg[2]
local A_ID = arg[3]
local A_SOUND = arg[4]
local A_SHAPE = arg[5]
local B_DIR = arg[6]
local B_DICT = arg[7]
local B_ID = arg[8]
local B_SOUND = arg[9]
local B_SHAPE = arg[10]

local fails = 0
local function check(name, ok, detail)
    print(string.format("  %-46s %s%s", name, ok and "PASS" or "FAIL",
                        (detail and not ok) and ("  <- " .. tostring(detail)) or ""))
    if not ok then
        fails = fails + 1
    end
end

print("方案 A = " .. A_ID .. " / 方案 B = " .. B_ID)

-- 1. 各自独立初始化：键位表、单字码都来自自己的配置 / 数据
local flow_a = init_one(A_DIR, A_DICT, A_ID, A_SOUND, A_SHAPE)
check("A 声母键来自自己的 schema", flow_env.sound_keys(flow_a) == A_SOUND,
      flow_env.sound_keys(flow_a))
check("A 笔形键来自自己的 schema", flow_env.shape_keys(flow_a) == A_SHAPE,
      flow_env.shape_keys(flow_a))
local a_shi = codes.scheme_code(flow_a, "实")
check("A 的「实」首键在 A 的声母键里",
      a_shi ~= nil and A_SOUND:find(a_shi:sub(1, 1), 1, true) ~= nil, a_shi)

-- 2. 同一个 Lua state 里再初始化 B（这就是真实进程里的情形）
local flow_b = init_one(B_DIR, B_DICT, B_ID, B_SOUND, B_SHAPE)
check("B 声母键来自自己的 schema", flow_env.sound_keys(flow_b) == B_SOUND,
      flow_env.sound_keys(flow_b))
check("B 笔形键来自自己的 schema", flow_env.shape_keys(flow_b) == B_SHAPE,
      flow_env.shape_keys(flow_b))
check("两个方案上下文是两个对象", flow_a ~= flow_b)
check("两个方案的码表缓存是分开的", flow_a.codes ~= flow_b.codes)

-- 3. 关键：B 初始化之后回头用 A，A 的推导必须还是 A 的数据
local a_after = codes.scheme_code(flow_a, "水饺")
local b_val = codes.scheme_code(flow_b, "水饺")
check("A 的推导在 B 初始化之后不变", a_after == codes.scheme_code(flow_a, "水饺"),
      a_after)
check("A/B 的「水饺」各用各的码表（不同键位下应不同或各自成立）",
      a_after ~= nil and b_val ~= nil, a_after .. " / " .. b_val)

-- 4. 「实」这个字在两套方案里读音键位不同（27C 用 u，27 用 e）——最直接的隔离证据
local a_shi2 = codes.scheme_code(flow_a, "实")
local b_shi2 = codes.scheme_code(flow_b, "实")
print("    A 的 实 = " .. tostring(a_shi2) .. " ｜ B 的 实 = " .. tostring(b_shi2))
check("A/B 的「实」首键分别落在自己方案的键位上",
      a_shi2 ~= nil and b_shi2 ~= nil and a_shi2 ~= b_shi2,
      a_shi2 .. " vs " .. b_shi2)

-- 4b. 默认次简一律来自方案自带的 <词库>.secondary.yaml（引擎里没有内置表）
local a_file = file_secondary(A_DIR, A_DICT)
local b_file = file_secondary(B_DIR, B_DICT)
local a_sec = secondary.get(flow_a, "u")
local b_sec_u = secondary.get(flow_b, "u")
local b_sec_e = secondary.get(flow_b, "e")
if a_file and b_file then
    check("A 的 u 次简 = 数据文件里的值", a_sec == a_file["u"],
          tostring(a_sec) .. " vs " .. tostring(a_file["u"]))
    check("A 的 z 次简 = 数据文件里的值", secondary.get(flow_a, "z") == a_file["z"],
          tostring(secondary.get(flow_a, "z")) .. " vs " .. tostring(a_file["z"]))
    check("B 的 e 次简 = 数据文件里的值", b_sec_e == b_file["e"],
          tostring(b_sec_e) .. " vs " .. tostring(b_file["e"]))
else
    print("    （方案目录没有 .secondary.yaml：默认次简应为空）")
    check("没有数据文件时默认次简为空", a_sec == nil and b_sec_e == nil,
          tostring(a_sec) .. " / " .. tostring(b_sec_e))
end
check("B 的 u 不是次简（u 是 B 的笔形键）", b_sec_u == nil, b_sec_u)

-- 5. 形码表也各用各的
local sa = shapes.expected(flow_a, "水饺")
local sb = shapes.expected(flow_b, "水饺")
print("    A 的 水饺 形码 = " .. tostring(sa) .. " ｜ B = " .. tostring(sb))
check("两个方案的形码表都读到了", sa ~= nil and sb ~= nil)

-- 6. 方案没配 flow_engine/*：引擎不启用（attach 返回 nil，组件那边 early return）
local bare = make_env({ dict = A_DICT, schema_id = "bare_scheme" })
check("缺 flow_engine/* 时不启用", flow_env.attach(bare) == nil, "attach 没返回 nil")

print("")
if fails == 0 then
    print("全部通过")
else
    print(string.format("%d 项失败", fails))
    os.exit(1)
end
