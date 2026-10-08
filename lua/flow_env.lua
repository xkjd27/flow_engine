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

-- 动作键：schema 的 flow_engine/bindings 里配（键名写法同 rime 的 key_binder：
-- minus / equal / Tab / F19…，单个字符也行，直接写 "-"）。
--
--   promote  正常模式：调序上调        demote  正常模式：降档延长
--   create   造词模式：入库            delete  造词模式：删除
--
-- create / delete 不写就跟 promote / demote 同键 —— 默认就是一个「-」一个「=」
-- 在两种场合各做一件事。配成空串 = 这个动作不绑键；键名不认识 = 当作没绑，只打 warning。
-- 返回 { promote=<keycode>, demote, create, delete }（0 = 没绑），按方案缓存。
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

function M.bindings(ctx)
    local st = M.cache(ctx, "bindings", {})
    if not st.ready then
        local promote = get_str(ctx.config, "flow_engine/bindings/promote", nil)
        local demote = get_str(ctx.config, "flow_engine/bindings/demote", nil)
        local create = get_str(ctx.config, "flow_engine/bindings/create", nil)
        local delete = get_str(ctx.config, "flow_engine/bindings/delete", nil)
        if create == nil then
            create = promote
        end
        if delete == nil then
            delete = demote
        end
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
        st.create = keycode_of(ctx, "flow_engine/bindings/create", create)
        st.delete = keycode_of(ctx, "flow_engine/bindings/delete", delete)
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
