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

-- 读数据文件（整块读，找不到返回 nil）
function M.read(ctx, suffix)
    for _, path in ipairs(M.paths(ctx, suffix)) do
        local f = io.open(path, "r")
        if f then
            local buf = f:read("a")
            f:close()
            if buf then
                return buf, path
            end
        end
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
function M.attach(env)
    local flow = M.ctx(env)
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
-- 两套方案只差这两个字母表，直接写进各自的 schema：
--   flow_engine:
--     sound_keys: "bcdfghjklmnpqrstuwxyz;"   # 声母键
--     shape_keys: "aeiov"                     # 笔形键
-- 读不到就用默认值并告警（旧部署副本里没有这段配置时）。

local DEFAULT_SOUND_KEYS = "bcdfghjklmnpqrstuwxyz;"
local DEFAULT_SHAPE_KEYS = "aeiov"

function M.shape_keys(ctx)
    local keys = get_str(ctx.config, "flow_engine/shape_keys", nil)
    if not keys then
        if log and log.warning then
            log.warning("flow_env: schema 里没有 flow_engine/shape_keys，"
                        .. "用默认笔形键 " .. DEFAULT_SHAPE_KEYS)
        end
        keys = DEFAULT_SHAPE_KEYS
    end
    return keys
end

function M.sound_keys(ctx)
    local keys = get_str(ctx.config, "flow_engine/sound_keys", nil)
    if not keys then
        if log and log.warning then
            log.warning("flow_env: schema 里没有 flow_engine/sound_keys，"
                        .. "用默认声母键 " .. DEFAULT_SOUND_KEYS)
        end
        keys = DEFAULT_SOUND_KEYS
    end
    return keys
end

-- 输入串是否「只有笔形键」（纯笔码）
function M.is_shape_input(ctx, s)
    if not s or s == "" then
        return false
    end
    return s:match("^[" .. M.shape_keys(ctx) .. "]+$") ~= nil
end

return M
