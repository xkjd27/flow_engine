-- 键道 Flow 共享引擎 —— 候选音码推导（用于「还需要按什么键」提示）
--
-- 提示只需要单字码（好 -> h hz、会 -> h hb k kd），词组的音码按码表规则拼：
--   * 2 字：音音全码（原 fg + 神 uk = fguk）
--   * 3/4 字：各字首键
--   * 5+ 字：前三首 + 末一首
-- 推导结果只用来给候选显示提示键，不参与候选匹配。
--
-- 单字码和读音权重都来自方案自带的单字表 <词库>.danzi.dict.yaml；
-- 再补上形码表 <词库>.shape.dict.yaml 里的条目（乛 亻 扌 这类只出现在
-- 形码表里的部件，词库里没有单字条目，少了它们这些候选就没提示码）。
-- 单字表的顺序不可靠（了 -> l,lc,lf），低权重读音会让提示指错 —— 所以按
-- 权重挑最重的读音补全。
--
-- 每个方案（schema_id）各自一份状态：见 flow_env.lua。

local flow_env = require("flow_env")

local M = {}

local function state(ctx)
    return flow_env.cache(ctx, "codes",
                          { char_cache = {}, word_cache = {}, codes = {},
                            ready = false })
end

local function utf8_chars(text)
    local chars = {}
    for _, c in utf8.codes(text) do
        chars[#chars + 1] = utf8.char(c)
    end
    return chars
end

-- 读单字表 / 形码表，建「字 -> {码 = 权重}」（同码取最大权重）
-- 整块读 + 一遍 gmatch：逐行 io.lines + 每行 match 要慢一倍
local function add_table(st, ctx, suffix, optional)
    local buf = flow_env.read(ctx, suffix)
    if not buf then
        if not optional and log and log.warning then
            log.warning("flow_codes: 读不到 " ..
                        tostring(flow_env.base_name(ctx.dict)) .. suffix ..
                        "（所有单字都没有提示码）")
        end
        return false
    end
    for ch, code, w in buf:gmatch("([^\t\n]+)\t([^\t\n]+)\t([%d%.]+)\n") do
        local t = st.codes[ch]
        if not t then
            t = {}
            st.codes[ch] = t
        end
        local n = tonumber(w) or 0
        if n > (t[code] or -1) then
            t[code] = n
        end
    end
    return true
end

local function load_tables(st, ctx)
    local ok = add_table(st, ctx, ".danzi.dict.yaml", false)
    if not ok then
        return false
    end
    -- 形码表是可选的：没有就少一批笔画/部首部件的码
    add_table(st, ctx, ".shape.dict.yaml", true)
    return true
end

function M.init(ctx)
    local st = ctx.codes
    if st and st.ready then
        return true
    end
    st = { char_cache = {}, word_cache = {}, codes = {}, ready = false }
    ctx.codes = st
    flow_env.cache(ctx, "codes", st)
    if not ctx.dict then
        log.warning("flow_codes: schema 里没有 translator/dictionary")
        return false
    end
    if not load_tables(st, ctx) then
        return false
    end
    st.ready = true
    return true
end

-- 单字的所有音码（1 键简码 + 全码，多音字有多个），按读音权重降序
local function char_entries(ctx, ch)
    local st = state(ctx)
    local cached = st.char_cache[ch]
    if cached then
        return cached
    end
    local list = {}
    local codes_of = st.codes[ch]
    if codes_of then
        for code, w in pairs(codes_of) do
            list[#list + 1] = { code = code, w = w }
        end
    end
    table.sort(list, function(a, b)
        if a.w ~= b.w then
            return a.w > b.w
        end
        return a.code < b.code
    end)
    st.char_cache[ch] = list
    return list
end

-- 推导候选词的音码：返回 {code=码, w=权重} 列表（多音字会得到多个候选码）
local function build_codes(ctx, text)
    local st = state(ctx)
    local cached = st.word_cache[text]
    if cached then
        return cached
    end
    local chars = utf8_chars(text)
    local n = #chars
    local result = {}
    if n == 1 then
        for _, e in ipairs(char_entries(ctx, chars[1])) do
            result[#result + 1] = e
        end
    elseif n == 2 then
        local a, b = char_entries(ctx, chars[1]), char_entries(ctx, chars[2])
        for _, ca in ipairs(a) do
            if #ca.code >= 2 then
                for _, cb in ipairs(b) do
                    if #cb.code >= 2 then
                        result[#result + 1] =
                            { code = ca.code .. cb.code, w = ca.w + cb.w }
                    end
                end
            end
        end
    else
        local idx = {}
        if n >= 5 then
            idx = { 1, 2, 3, n }
        else
            for i = 1, n do
                idx[#idx + 1] = i
            end
        end
        -- 各字的声母首键 -> 该键上的最大读音权重
        local initials = {}
        for _, i in ipairs(idx) do
            local best = {}
            for _, e in ipairs(char_entries(ctx, chars[i])) do
                local k = e.code:sub(1, 1)
                if k ~= "" and (best[k] == nil or e.w > best[k]) then
                    best[k] = e.w
                end
            end
            initials[#initials + 1] = best
        end
        local function combine(i, acc, w)
            if i > #initials then
                result[#result + 1] = { code = acc, w = w }
                return
            end
            for k, kw in pairs(initials[i]) do
                combine(i + 1, acc .. k, w + kw)
            end
        end
        combine(1, "", 0)
    end
    -- 去重（同码取最大权重），按权重降序
    local uniq = {}
    local out = {}
    for _, e in ipairs(result) do
        local cur = uniq[e.code]
        if not cur then
            uniq[e.code] = e
            out[#out + 1] = e
        elseif e.w > cur.w then
            cur.w = e.w
        end
    end
    table.sort(out, function(a, b)
        if a.w ~= b.w then
            return a.w > b.w
        end
        return a.code < b.code
    end)
    st.word_cache[text] = out
    return out
end

-- input 之后还需要输入的声码（按最重读音补全），没有则返回 nil
function M.next_keys(ctx, text, input)
    local best, best_w = nil, nil
    for _, e in ipairs(build_codes(ctx, text)) do
        local code = e.code
        if #code > #input and code:sub(1, #input) == input then
            local rest = code:sub(#input + 1)
            if not best or e.w > best_w or
                    (e.w == best_w and #rest < #best) then
                best, best_w = rest, e.w
            end
        end
    end
    return best
end

-- 词组的方案码（取权重最高的推导码）：2 字音音全码 / 3-4 字首字母 /
-- 5+ 字前三首 + 末首；多音字按单字表权重挑。
function M.scheme_code(ctx, text)
    local list = build_codes(ctx, text)
    return list[1] and list[1].code
end

-- code 是否是 text 的一个方案码（含多音变体）
function M.is_scheme_code(ctx, text, code)
    for _, e in ipairs(build_codes(ctx, text)) do
        if e.code == code then
            return true
        end
    end
    return false
end

return M
