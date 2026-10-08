-- 键道 Flow 共享引擎 —— 手动调序存储
--
-- 两种后端（schema 配置 flow_order/backend，用户可用 .custom 覆盖）：
--   leveldb : Rime 原生 userdb（leveldb）   -> <user>/<name>.userdb/
--   txt     : 本模块写的纯文本               -> <user>/<name>.txt
--
-- （librime 的 plain_userdb/tabledb 只接受「code+tab+词」这种用户词典
--   key 格式，不适合当通用 KV，配置成 tabledb 会退回 txt。）
--
-- 内存里始终有一份 order[key] = {候选1, 候选2...}，查询 O(1)；
-- 只有 insert/remove/move_down/remove_word 时才写后端
-- （db 单键写，txt 整文件重写）。remove_word 是反查删除（造词用）：
-- leveldb 没有反向索引，但全部 pin 都在内存里（st.order），扫一遍即可。
--
-- value 格式：条目用 \t 分隔；条目 = 候选词，或
--   「候选词 + 空格 + 完整音节」（音码削减过的 pin，如 ``你 ny``），
--   供 `=` 还原到完整音节时使用（没有记录时回退反查）。
-- 另有特殊 key "~recent"：最近造词记录（造词模式只按 ` 时列出、= 删除）。
-- 另一个特殊键不是单个 key：声笔简码覆盖按码存，一码一条 "sbb/<码>"
-- （值=文本；没有就是不覆盖，回默认表）。
-- 特殊 key "~secondary"：次简表（码=文本，Tab 学习/用户覆盖）。
--
-- 调试用 .custom 切到 txt 即可手改数据。
--
-- 每个方案（schema_id）各自一份状态（含自己的 leveldb 句柄），见 flow_env.lua。

local flow_env = require("flow_env")

local M = {}

local KEY_PREFIX = "ord/"
local SECONDARY_KEY = "~secondary"
-- 声笔简码覆盖：内存里是一张 code -> 文本 的表；后端里**一个码一条 key**
-- （sbb/<码>），set/clear 只动单条，不整表重写。
local SHENGBI_PREFIX = "sbb/"
local RECENT_KEY = "~recent"

local function state(flow)
    return flow_env.cache(flow, "order", {
        order = {},
        syllables = {},
        secondary = {},
        shengbi = {},
        users = 0,
        ready = false,
        backend = "leveldb",
        recent_max = 20,
    })
end

local function user_dir()
    if rime_api and rime_api.get_user_data_dir then
        return rime_api.get_user_data_dir()
    end
    return "."
end

-- 解析 value -> st.order[key] / st.syllables[key]
local function parse_value(st, key, value)
    local list = {}
    local syls = nil
    for entry in value:gmatch("[^\t]+") do
        local text, syl = entry:match("^(.-) (.*)$")
        if text and syl and syl ~= "" then
            list[#list + 1] = text
            syls = syls or {}
            syls[text] = syl
        else
            list[#list + 1] = entry
        end
    end
    st.order[key] = list
    st.syllables[key] = syls
end

local function serialize_value(st, key)
    local list = st.order[key]
    if not list or #list == 0 then
        return nil
    end
    local syls = st.syllables[key]
    local parts = {}
    for i, text in ipairs(list) do
        local syl = syls and syls[text]
        parts[i] = syl and (text .. " " .. syl) or text
    end
    return table.concat(parts, "\t")
end

-- ---------------- 次简表（特殊 key ~secondary） ----------------
-- value 格式：码=文本，\t 分隔；文本为空表示「取消默认次简」。
-- 码和用户实际敲的键一致（音码 + 形码，如 z / zto / br / o）。

local function parse_secondary(st, value)
    st.secondary = {}
    for entry in value:gmatch("[^\t]+") do
        local code, text = entry:match("^(.-)=(.*)$")
        if code and code ~= "" then
            st.secondary[code] = text
        end
    end
end

local function serialize_secondary(st)
    local parts = {}
    for code, text in pairs(st.secondary) do
        parts[#parts + 1] = code .. "=" .. text
    end
    if #parts == 0 then
        return nil
    end
    table.sort(parts)
    return table.concat(parts, "\t")
end

-- ---------------- 声笔简码覆盖（后端 key = sbb/<码>） ----------------
-- 值就是文本；没有这条 key 就是没覆盖（回默认表，见 flow_shengbi）。
-- 一个码一条 key：声笔码数量多时也只读写单条，内存里 hash 查表 O(1)。
-- 写入口 save_shengbi 在 save_key 后面（它要用到保存函数）。

-- ---------------- txt 后端 ----------------

local function load_txt(st)
    st.shengbi = {}
    local f = io.open(st.path, "r")
    if not f then
        return
    end
    for line in f:lines() do
        if line ~= "" and line:sub(1, 1) ~= "#" then
            local fields = {}
            for field in line:gmatch("[^\t]+") do
                fields[#fields + 1] = field
            end
            if #fields >= 2 then
                if fields[1] == SECONDARY_KEY then
                    parse_secondary(st, table.concat(fields, "\t", 2))
                elseif fields[1]:sub(1, #SHENGBI_PREFIX) == SHENGBI_PREFIX then
                    st.shengbi[fields[1]:sub(#SHENGBI_PREFIX + 1)] =
                        table.concat(fields, "\t", 2)
                else
                    parse_value(st, fields[1], table.concat(fields, "\t", 2))
                end
            end
        end
    end
    f:close()
end

local function save_txt(st)
    local f = io.open(st.path, "w")
    if not f then
        return
    end
    f:write("# key\t候选（越靠前越优先；音码削减过的带完整音节）\n")
    for key in pairs(st.order) do
        local value = serialize_value(st, key)
        if value then
            f:write(key, "\t", value, "\n")
        end
    end
    local sec = serialize_secondary(st)
    if sec then
        f:write(SECONDARY_KEY, "\t", sec, "\n")
    end
    local codes = {}
    for code in pairs(st.shengbi) do
        codes[#codes + 1] = code
    end
    table.sort(codes)
    for _, code in ipairs(codes) do
        f:write(SHENGBI_PREFIX, code, "\t", st.shengbi[code], "\n")
    end
    f:close()
end

-- ---------------- db 后端 ----------------

local function load_db(st)
    local acc = st.db:query(KEY_PREFIX)
    if not acc then
        return
    end
    for k, v in acc:iter() do
        local key = k:sub(#KEY_PREFIX + 1)
        if key == SECONDARY_KEY then
            parse_secondary(st, v)
        else
            parse_value(st, key, v)
        end
    end
    -- DbAccessor 要先释放，之后 close 才安全
    acc = nil
    collectgarbage()

    st.shengbi = {}
    local sacc = st.db:query(SHENGBI_PREFIX)
    if not sacc then
        return
    end
    for k, v in sacc:iter() do
        st.shengbi[k:sub(#SHENGBI_PREFIX + 1)] = v
    end
    sacc = nil
    collectgarbage()
end

local function save_key(st, key)
    if st.backend == "txt" then
        save_txt(st)
        return
    end
    if not st.db then
        return
    end
    local value
    if key == SECONDARY_KEY then
        value = serialize_secondary(st)
    else
        value = serialize_value(st, key)
    end
    if value then
        st.db:update(KEY_PREFIX .. key, value)
    else
        st.db:erase(KEY_PREFIX .. key)
    end
end

-- 声笔简码覆盖的单条写入（一个码一条 key）
local function save_shengbi(st, code)
    if st.backend == "txt" then
        save_txt(st)
        return
    end
    if not st.db then
        return
    end
    local text = st.shengbi[code]
    if text ~= nil then
        st.db:update(SHENGBI_PREFIX .. code, text)
    else
        st.db:erase(SHENGBI_PREFIX .. code)
    end
end

-- ---------------- 公共接口 ----------------

function M.init(flow)
    local st = state(flow)
    st.users = st.users + 1
    if st.ready then
        return
    end
    st.order = {}
    st.syllables = {}
    local backend = flow_env.get_string(flow, "flow_order/backend", "leveldb")
    local name = flow_env.get_string(flow, "flow_order/name", nil)
    if not name then
        name = tostring(flow.dict) .. ".order"
    end
    st.backend = backend
    st.name = name
    local rmax = flow_env.get_int(flow, "flow_order/recent_max", nil)
    if rmax and rmax > 0 then
        st.recent_max = rmax
    end
    if backend == "tabledb" then
        -- plain_userdb 不适合做通用 KV，退回 txt
        log.warning("flow_order: tabledb unsupported, fallback to txt")
        backend = "txt"
        st.backend = "txt"
    end

    if backend == "txt" then
        st.path = user_dir() .. "/" .. name .. ".txt"
        load_txt(st)
    else
        local db
        if LevelDb then
            db = LevelDb(name)
        end
        if db then
            if not db:loaded() then
                db:open()
            end
            if db:loaded() then
                st.db = db
                load_db(st)
            end
        end
        if not st.db then
            -- 后端不可用则退回 txt
            backend = "txt"
            st.backend = "txt"
            st.path = user_dir() .. "/" .. name .. ".txt"
            load_txt(st)
            log.warning("flow_order: db backend unavailable, fallback to txt")
        end
    end
    st.ready = true
end

-- 组件 fini 里调：引用计数减到 0 就关库
-- （librime-lua 只在组件析构时调 fini，所以 init 这里加计数，别的地方别加）
function M.close(flow)
    local st = state(flow)
    if st.users > 0 then
        st.users = st.users - 1
    end
    if st.users > 0 then
        return
    end
    if st.db then
        st.db:close()
        st.db = nil
    end
    -- 允许下次 init 重新打开（部署/重建引擎时会 fini + init）
    st.ready = false
end

function M.get(flow, key)
    return state(flow).order[key]
end

-- text 在 input 下的 pin 级别（形码串；没有 pin 则 nil）
function M.pin_level(flow, input, text)
    if not input or input == "" or not text or text == "" then
        return nil
    end
    local prefix = input .. "|"
    local n = #prefix
    for key, list in pairs(state(flow).order) do
        if key:sub(1, n) == prefix then
            for _, t in ipairs(list) do
                if t == text then
                    return key:sub(n + 1)
                end
            end
        end
    end
    return nil
end

-- 把 text 从所有 pin 里删掉（保留 ~recent / ~secondary 特殊键）。
-- 调频时词可能只以「补全」身份出现在当前级别（真正的 pin 在别的级别），
-- 只 remove 当前 key 清不到，会留下重复 pin；所以移动 pin 前用这个。
function M.remove_pin(flow, text)
    if not text or text == "" then
        return
    end
    local keys = {}
    for key, list in pairs(state(flow).order) do
        if key:find("|", 1, true) then
            for _, t in ipairs(list) do
                if t == text then
                    keys[#keys + 1] = key
                    break
                end
            end
        end
    end
    for _, key in ipairs(keys) do
        M.remove(flow, key, text)
    end
end

-- 列出同音码下所有形码级别的 pin（不含 ~ 特殊键）：
-- 返回 { { key = 完整键, shape = 形码级别, list = 候选列表 }, ... }。
-- 自造词只存在 pin 里，输入更短的码时也要能像词库词一样看到它，
-- flow_filter 用这个做「同音码补全」。
function M.pins_under(flow, input)
    if not input or input == "" then
        return {}
    end
    local prefix = input .. "|"
    local n = #prefix
    local out = {}
    for key, list in pairs(state(flow).order) do
        if key:sub(1, n) == prefix then
            out[#out + 1] = {
                key = key,
                shape = key:sub(n + 1),
                list = list,
            }
        end
    end
    return out
end

-- 次简覆盖：nil = 没有覆盖；"" = 显式取消（盖掉默认）
function M.get_secondary(flow, code)
    return state(flow).secondary[code]
end

-- 记一条次简覆盖/学习；text 为空表示取消该码的默认次简
function M.set_secondary(flow, code, text)
    if not code or code == "" then
        return
    end
    local st = state(flow)
    st.secondary[code] = text or ""
    save_key(st, SECONDARY_KEY)
end

-- 声笔简码覆盖：nil = 没有覆盖；"" = 显式取消（盖掉默认表）
function M.get_shengbi(flow, code)
    return state(flow).shengbi[code]
end

-- 记一条声笔简码（`` ` ` 调整模式设的 sb / sbb）；text 为空 = 取消该码
function M.set_shengbi(flow, code, text)
    if not code or code == "" then
        return
    end
    local st = state(flow)
    st.shengbi[code] = text or ""
    save_shengbi(st, code)
end

-- 删掉覆盖，回默认表（正常模式按 = 还原）
function M.clear_shengbi(flow, code)
    local st = state(flow)
    if st.shengbi[code] == nil then
        return
    end
    st.shengbi[code] = nil
    save_shengbi(st, code)
end

-- 把 text 从声笔简码覆盖里全删掉（同一个词换码时用；与 pin 无关，
-- 所以造词模式的 remove_word 不会碰 ~shengbi）
function M.remove_shengbi_word(flow, text)
    if not text or text == "" then
        return
    end
    local st = state(flow)
    local hits = {}
    for code, t in pairs(st.shengbi) do
        if t == text then
            st.shengbi[code] = nil
            hits[#hits + 1] = code
        end
    end
    for _, code in ipairs(hits) do
        save_shengbi(st, code)
    end
end

-- 音码削减过的候选 @ key 上保存的完整音节
function M.get_syllable(flow, key, text)
    local syls = state(flow).syllables[key]
    return syls and syls[text] or nil
end

-- 把 text 放到 key 的第 index 位（默认第 1 位）；syl 非空时记录完整音节
function M.insert(flow, key, text, index, syl)
    local st = state(flow)
    local list = st.order[key]
    if not list then
        list = {}
        st.order[key] = list
    end
    for i = #list, 1, -1 do
        if list[i] == text then
            table.remove(list, i)
        end
    end
    index = index or 1
    if index < 1 then
        index = 1
    elseif index > #list + 1 then
        index = #list + 1
    end
    table.insert(list, index, text)
    if syl and syl ~= "" then
        st.syllables[key] = st.syllables[key] or {}
        st.syllables[key][text] = syl
    end
    save_key(st, key)
end

-- 把 text 从 key 的手动列表里移出（空则删除整个 key）
function M.remove(flow, key, text)
    local st = state(flow)
    local list = st.order[key]
    if not list then
        return
    end
    for i = #list, 1, -1 do
        if list[i] == text then
            table.remove(list, i)
        end
    end
    local syls = st.syllables[key]
    if syls then
        syls[text] = nil
        if not next(syls) then
            st.syllables[key] = nil
        end
    end
    if #list == 0 then
        st.order[key] = nil
        st.syllables[key] = nil
    end
    save_key(st, key)
end

-- 反查删除（造词用）：把 text 从**所有** key 里删掉（含最近造词记录），
-- 返回删掉的条数。leveldb 本身没有反向索引，但 init 时已经把全部 pin
-- 读进了内存（st.order: key -> {词...}），所以反查就是扫一遍内存表；
-- 受影响的 key 逐个写回后端（db 单键写 / txt 整文件重写），不需要额外
-- 维护索引。
function M.remove_word(flow, text)
    if not text or text == "" then
        return 0
    end
    local st = state(flow)
    local removed = 0
    local keys = {}
    for key in pairs(st.order) do
        keys[#keys + 1] = key
    end
    for _, key in ipairs(keys) do
        local list = st.order[key]
        local hit = false
        for i = #list, 1, -1 do
            if list[i] == text then
                table.remove(list, i)
                removed = removed + 1
                hit = true
            end
        end
        if hit then
            local syls = st.syllables[key]
            if syls then
                syls[text] = nil
                if not next(syls) then
                    st.syllables[key] = nil
                end
            end
            if #list == 0 then
                st.order[key] = nil
                st.syllables[key] = nil
            end
            save_key(st, key)
        end
    end
    return removed
end

-- ---------------- 最近造词（造词模式只按 ` 时列出、= 删除） ----------------

-- 记一条最近造词：去重后放最前，截到 recent_max
function M.touch_recent(flow, text)
    if not text or text == "" then
        return
    end
    local st = state(flow)
    local list = st.order[RECENT_KEY]
    if not list then
        list = {}
        st.order[RECENT_KEY] = list
    end
    for i = #list, 1, -1 do
        if list[i] == text then
            table.remove(list, i)
        end
    end
    table.insert(list, 1, text)
    for i = #list, st.recent_max + 1, -1 do
        table.remove(list, i)
    end
    save_key(st, RECENT_KEY)
end

-- 最近造词（最多 limit 条，默认全部）
function M.recent(flow, limit)
    local list = state(flow).order[RECENT_KEY]
    if not list then
        return {}
    end
    limit = limit or #list
    local out = {}
    for i = 1, math.min(limit, #list) do
        out[i] = list[i]
    end
    return out
end

-- 把 text 往下移一位；已在末位则移出手动列表
function M.move_down(flow, key, text)
    local st = state(flow)
    local list = st.order[key]
    if not list then
        return
    end
    for i, t in ipairs(list) do
        if t == text then
            if i == #list then
                table.remove(list, i)
                local syls = st.syllables[key]
                if syls then
                    syls[text] = nil
                    if not next(syls) then
                        st.syllables[key] = nil
                    end
                end
                if #list == 0 then
                    st.order[key] = nil
                    st.syllables[key] = nil
                end
            else
                list[i], list[i + 1] = list[i + 1], list[i]
            end
            save_key(st, key)
            return
        end
    end
end

-- 把 text 往下移一位；已在末位则保留（不删）。
-- 自造词只存在 pin 里，到完整形码后 `=` 再用 move_down 会把词整条
-- 删掉（从所有级别消失），所以这条路径用它：末位就待在末位。
function M.move_down_keep(flow, key, text)
    local st = state(flow)
    local list = st.order[key]
    if not list then
        return
    end
    for i, t in ipairs(list) do
        if t == text then
            if i < #list then
                list[i], list[i + 1] = list[i + 1], list[i]
                save_key(st, key)
            end
            return
        end
    end
end

return M
