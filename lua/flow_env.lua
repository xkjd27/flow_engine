-- 键道 Flow 共享引擎 —— 每方案上下文
--
-- 键道27・流 和 键道27C・流 挂同一份引擎（本仓库），所以引擎里不能留任何
-- 「当前方案」的全局状态：一个 rime 进程只有一个 Lua state，两个方案同时装、
-- 同一个进程里切换时，模块级变量会被先加载的方案占住（提示权重、造词码就会
-- 用错方案的数据）。
--
-- 这里把每个方案的东西按 schema_id 分开存：字典名、键位表、缓存、order 库、
-- 单字权重表、形码表、次简覆盖……组件通过 env 进来时取自己那一份。
--
-- 方案之间的差异只走两条路：
--   1. schema 配置（translator/dictionary、flow_order/*、speller/alphabet、
--      可选的 flow_engine/* 键位表）；
--   2. 数据文件（<词库>.danzi.dict.yaml、<词库>.shape.txt）。

local M = {}

local contexts = {}   -- schema_id -> ctx（同一方案的两个组件共用一份）

local function data_dirs()
    local dirs = {}
    if rime_api and rime_api.get_user_data_dir then
        dirs[#dirs + 1] = rime_api.get_user_data_dir()
    end
    if rime_api and rime_api.get_shared_data_dir then
        dirs[#dirs + 1] = rime_api.get_shared_data_dir()
    end
    if #dirs == 0 then
        dirs[1] = "."
    end
    return dirs
end

local function config_of(env)
    local ok, config = pcall(function()
        return env.engine.schema.config
    end)
    if ok then
        return config
    end
    return nil
end

local function get_str(config, key, default)
    if not config then
        return default
    end
    local ok, value = pcall(function()
        return config:get_string(key)
    end)
    if ok and value and value ~= "" then
        return value
    end
    return default
end

-- 配置读取（给各模块用；schema 配置缺失时给默认值）
function M.get_string(flow, key, default)
    return get_str(flow and flow.config, key, default)
end

function M.get_bool(flow, key, default)
    if not flow or not flow.config then
        return default
    end
    local ok, value = pcall(function()
        return flow.config:get_bool(key)
    end)
    if ok and value ~= nil then
        return value
    end
    return default
end

function M.get_int(flow, key, default)
    if not flow or not flow.config then
        return default
    end
    local ok, value = pcall(function()
        return flow.config:get_int(key)
    end)
    if ok and value ~= nil then
        return value
    end
    return default
end

-- 词库名去掉变体后缀：xkjd27c_flow.ice -> xkjd27c_flow（数据文件按基础名命名）
function M.base_name(dict)
    if not dict then
        return nil
    end
    local base = dict:match("^(.-)%.[^%.]+$")
    return base or dict
end

-- 找数据文件：先按词库全名、再按基础名；用户目录优先于共享目录
function M.paths(ctx, suffix)
    local names = {}
    if ctx.dict then
        names[#names + 1] = ctx.dict
    end
    local base = M.base_name(ctx.dict)
    if base and base ~= ctx.dict then
        names[#names + 1] = base
    end
    local paths = {}
    for _, dir in ipairs(data_dirs()) do
        for _, name in ipairs(names) do
            paths[#paths + 1] = dir .. "/" .. name .. suffix
        end
    end
    return paths
end

-- 找数据文件，返回第一个存在的路径（找不到返回 nil）
function M.find(ctx, suffix)
    for _, path in ipairs(M.paths(ctx, suffix)) do
        local f = io.open(path, "r")
        if f then
            f:close()
            return path
        end
    end
    return nil
end

-- 读数据文件（整块读，找不到返回 nil）
function M.read(ctx, suffix)
    local path = M.find(ctx, suffix)
    if not path then
        return nil
    end
    local f = io.open(path, "r")
    if not f then
        return nil
    end
    local buf = f:read("a")
    f:close()
    if buf then
        return buf, path
    end
    return nil
end

-- 取（或新建）方案上下文；不会动引用计数
function M.ctx(env)
    local config = config_of(env)
    local schema_id = get_str(config, "schema/schema_id", nil)
    if not schema_id then
        local ok, id = pcall(function()
            return env.engine.schema.schema_id
        end)
        schema_id = ok and id or "default"
    end
    local ctx = contexts[schema_id]
    if not ctx then
        ctx = {
            schema_id = schema_id,
            dict = get_str(config, "translator/dictionary", nil),
            config = config,
            users = 0,
            caches = {},   -- 各模块自己的缓存表，按模块名分
        }
        contexts[schema_id] = ctx
    else
        -- 部署/重建引擎后 schema 可能换了词库，跟着更新（缓存全部重建）
        ctx.config = config
        local dict = get_str(config, "translator/dictionary", nil)
        if dict and dict ~= ctx.dict then
            ctx.dict = dict
            ctx.caches = {}
            ctx.codes = nil
        end
    end
    return ctx
end

-- 组件 init 用：把本方案的 ctx 存进 env.flow，并记一次引用。
-- librime-lua 每个组件实例一个 env（init / fini / 每次调用拿到同一个），
-- 所以状态挂 env 上就好，不必每次按 schema_id 去查。
-- 方案没配齐（词库名 / 声母键 / 笔形键）时不设 env.flow：组件那边会
-- early return（filter 放行候选、processor 不处理按键），不半开半不开。
function M.attach(env)
    local flow = M.ctx(env)
    if not flow.dict then
        if log and log.error then
            log.error("flow_env: schema 里没有 translator/dictionary，引擎不启用")
        end
        return nil
    end
    if not (M.sound_keys(flow) and M.shape_keys(flow)) then
        return nil
    end
    env.flow = flow
    flow.users = flow.users + 1
    return flow
end

-- 组件的回调里取（init 里已经放好）；拿不到说明这个实例没初始化成功
function M.of(env)
    return env and env.flow or nil
end

-- 组件 fini 用：计数减到 0 就收尾（关 order 库、清缓存）
function M.release(env)
    local ctx = M.of(env) or M.ctx(env)
    if ctx.users > 0 then
        ctx.users = ctx.users - 1
    end
    if ctx.users == 0 then
        M.teardown(ctx)
    end
    return ctx
end

-- 放掉这个方案占的东西（order 的 leveldb 一定要关，否则同进程同步/删除 userdb
-- 会撞 LOCK）
function M.teardown(ctx)
    if ctx.on_teardown then
        ctx.on_teardown(ctx)
    end
    ctx.caches = {}
    ctx.reverse = nil
    ctx.shapes = nil
    ctx.secondary = nil
    ctx.order = nil
    ctx.codes = nil
end

function M.cache(ctx, name, init)
    local slot = ctx.caches[name]
    if not slot then
        slot = init or {}
        ctx.caches[name] = slot
    end
    return slot
end

-- 键位表 ---------------------------------------------------------------

-- 键位表 ---------------------------------------------------------------
-- 每个方案必须在自己的 schema 里写清楚，引擎不留任何内置默认值
-- （留一份就等于偏心某个方案）：
--   flow_engine:
--     sound_keys: "bcdfghjklmnpqrstuwxyz;"   # 声母键
--     shape_keys: "aeiov"                     # 笔形键
-- 缺了就当作「这个方案没打算用本引擎」：不启用（见 attach），只打一条 error。

local function required_keys(ctx, path, what)
    local keys = get_str(ctx.config, path, nil)
    if not keys and log and log.error then
        log.error("flow_env: schema 里没有 " .. path .. "（" .. what
                  .. "），引擎不启用")
    end
    return keys
end

function M.shape_keys(ctx)
    return required_keys(ctx, "flow_engine/shape_keys", "笔形键")
end

function M.sound_keys(ctx)
    return required_keys(ctx, "flow_engine/sound_keys", "声母键")
end

-- 动作键 / 翻页键：schema 的 flow_engine/bindings 里配（键名写法同 rime 的
-- key_binder：minus / equal / bracketleft / Tab / F19…，单个字符也行）。
--
--   promote    正常模式：调序上调；造词模式：入库；声笔调整模式：设为 sb
--   demote     正常模式：降档延长；造词模式：删除；声笔调整模式：设为 sbb
--   prev_page  上一页；next_page 下一页（可选：不配就完全不由引擎处理，
--              留给方案自己的 key_binder）
--
-- 配成空串 = 这个动作不绑键；键名不认识 = 当作没绑，只打 warning。
-- 返回 { promote=<keycode>, demote=<keycode>, prev_page=<keycode>,
--        next_page=<keycode>, edge=<翻页到头的行为> }（0 = 没绑），按方案缓存。
local function keycode_of(ctx, path, name)
    if name == nil or name == "" then
        return 0
    end
    local ok, ev = pcall(KeyEvent, name)
    local kc = (ok and ev and ev.keycode) or 0
    if kc == 0 and log and log.warning then
        log.warning("flow_env: " .. path .. " = '" .. tostring(name)
                    .. "' 不是有效的键名，这个动作键不生效")
    end
    return kc
end

-- 标点定义 -> 文本数组，写法与顺序照 librime 的 PunctTranslator：
--   字符串（唯一）/ 列表（全部给出来）/ {commit: …} / {pair: [a, b]}
-- 只取候选文本，不做 rime 那几个处理器动作（自动上屏 / 连按换候选）。
-- 列表下标是 rime 的 @0 写法（ConfigData::IsListItemReference）。
local function punct_texts(flow, path)
    local one = M.get_string(flow, path, nil)
    if one then
        return { one }
    end
    local list = {}
    for i = 0, 15 do
        local item = M.get_string(flow, path .. "/@" .. i, nil)
        if not item then
            break
        end
        list[#list + 1] = item
    end
    if #list > 0 then
        return list
    end
    local commit = M.get_string(flow, path .. "/commit", nil)
    if commit then
        return { commit }
    end
    local pair = {}
    for i = 0, 1 do
        local item = M.get_string(flow, path .. "/pair/@" .. i, nil)
        if not item then
            return nil
        end
        pair[#pair + 1] = item
    end
    return pair
end

-- 标点候选：schema 的 punctuator 段里这个键的定义（全角 / 半角各一份，
-- 跟其它标点同一处配置）。键可以是多字符：声母键里的标点连按两个（`;;`）
-- 就查 `punctuator/<shape>/;;`，rime 自带的标点处理不了多字符键
-- （PunctSegmentor 一次只看一个字符），由 flow_filter 拿这里的值插候选。
-- 返回文本数组；没配返回 nil（不插）。
function M.punctuation(flow, ctx, keys)
    if ctx:get_option("ascii_punct") then
        return nil
    end
    local shape = ctx:get_option("full_shape") and "full_shape"
                  or "half_shape"
    return punct_texts(flow, "punctuator/" .. shape .. "/" .. keys)
        or punct_texts(flow, "punctuator/symbols/" .. keys)
end

-- 标点候选的注释（〔半角〕/〔全角〕）：跟 librime 的 CreatePunctCandidate
-- 一致 —— 看字符本身，不看全角开关；不是单字符就不标。
function M.punct_comment(text)
    if not text or utf8.len(text) ~= 1 then
        return ""
    end
    local cp = utf8.codepoint(text)
    local half = (cp >= 0x20 and cp < 0x7f) or (cp >= 0xff61 and cp <= 0xff9f)
        or (cp >= 0xffa0 and cp <= 0xffdc) or cp == 0xa2 or cp == 0xa3
        or cp == 0xa5 or cp == 0xa6 or cp == 0xac or cp == 0xaf
        or cp == 0x2985 or cp == 0x2986 or (cp >= 0xffe8 and cp <= 0xffee)
    local full = cp == 0x3000 or (cp >= 0xff01 and cp <= 0xff5e)
        or (cp >= 0x30a1 and cp <= 0x30fc) or cp == 0x3001 or cp == 0x3002
        or cp == 0x300c or cp == 0x300d or cp == 0x309b or cp == 0x309c
        or (cp >= 0x3131 and cp <= 0x3164) or cp == 0xff5f or cp == 0xff60
        or (cp >= 0xffe0 and cp <= 0xffe6) or (cp >= 0x2190 and cp <= 0x2193)
        or cp == 0x2502 or cp == 0x25a0 or cp == 0x25cb
    if half then
        return "〔半角〕"
    end
    if full then
        return "〔全角〕"
    end
    return ""
end

-- 翻页键到头（第 1 页再往前 / 最后一页再往后）时的行为
-- （flow_engine/page_edge）：
--   ignore  无效翻页键，吞掉（默认）
--   topup   顶屏：当前内容上屏
--   pass    引擎不处理，交给后面的处理器（`[` 出「 这类标点候选）
local PAGE_EDGES = { ignore = true, topup = true, pass = true }

local function page_edge_of(ctx)
    local edge = get_str(ctx.config, "flow_engine/page_edge", "ignore")
    if not PAGE_EDGES[edge] then
        if log and log.warning then
            log.warning("flow_env: flow_engine/page_edge = '" .. tostring(edge)
                        .. "' 不认识（ignore / topup / pass），按 ignore")
        end
        return "ignore"
    end
    return edge
end

function M.bindings(ctx)
    local st = M.cache(ctx, "bindings", {})
    if not st.ready then
        local promote = get_str(ctx.config, "flow_engine/bindings/promote", nil)
        local demote = get_str(ctx.config, "flow_engine/bindings/demote", nil)
        local prev_page = get_str(ctx.config, "flow_engine/bindings/prev_page",
                                 nil)
        local next_page = get_str(ctx.config, "flow_engine/bindings/next_page",
                                 nil)
        if promote == nil and log and log.warning then
            log.warning("flow_env: schema 里没有 flow_engine/bindings/promote"
                        .. "（调序上调键），这个动作键不生效")
        end
        if demote == nil and log and log.warning then
            log.warning("flow_env: schema 里没有 flow_engine/bindings/demote"
                        .. "（降档延长键），这个动作键不生效")
        end
        st.promote = keycode_of(ctx, "flow_engine/bindings/promote", promote)
        st.demote = keycode_of(ctx, "flow_engine/bindings/demote", demote)
        st.prev_page = keycode_of(ctx, "flow_engine/bindings/prev_page",
                                  prev_page)
        st.next_page = keycode_of(ctx, "flow_engine/bindings/next_page",
                                  next_page)
        st.edge = page_edge_of(ctx)
        st.ready = true
    end
    return st
end

-- 输入串是否「只有笔形键」（纯笔码）；键位没配就当不是
function M.is_shape_input(ctx, s)
    if not s or s == "" then
        return false
    end
    local keys = M.shape_keys(ctx)
    if not keys then
        return false
    end
    return s:match("^[" .. keys .. "]+$") ~= nil
end

return M
