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

-- 字的首选读音声母键（声笔简码的「声」；取不到返回 nil）
function M.initial(ctx, ch)
    local sound = flow_env.sound_keys(ctx) or ""
    for _, e in ipairs(char_entries(ctx, ch)) do
        local key = e.code:sub(1, 1)
        if #key == 1 and sound:find(key, 1, true) then
            return key
        end
    end
    return nil
end

-- input 之后还需要输入的声码（按最重读音补全），没有则返回 nil
function M.next_keys(ctx, text, input)
    -- build_codes 已按（权重降序、码升序）排好：匹配的码里取权重最大、
    -- 同权重取最短；权重一旦低于已选中的最大值，后面不可能再赢，直接停。
    -- 原来的实现每命中一个码就先 sub 出 rest 再比长度，多一批白造的字符串。
    local n = #input
    local best, best_w
    for _, e in ipairs(build_codes(ctx, text)) do
        local code = e.code
        if #code > n and code:sub(1, n) == input then
            local w = e.w
            if best_w == nil or w > best_w or
                    (w == best_w and #code < #best) then
                best, best_w = code, w
            end
        end
        if best_w ~= nil and e.w < best_w then
            break
        end
    end
    if not best then
        return nil
    end
    return best:sub(n + 1)
end

-- 词组的方案码（取权重最高的推导码）：2 字音音全码 / 3-4 字首字母 /
-- 5+ 字前三首 + 末首；多音字按单字表权重挑。
function M.scheme_code(ctx, text)
    local list = build_codes(ctx, text)
    return list[1] and list[1].code
end

-- 正常单字判定（造词保底用）：它得有「音码开头、不超过 2 键」的码，而且
-- 所有音码开头的码都不能超过 2 键。形码开头的（aeiov）那一批是形码表里的
-- 部件/形简条目，不参与判断 —— 这样 又/得/有 这些常用字不会被它们拖累。
--   * 首码是笔形键的：只出现在形码表里的部件（亅 氵 乛…），没有音码；
--   * 音码超过 2 键的：多音节字（静态.txt 的 兡 兝 兞 瓩…，码是 3~6 键）；
--   * 压根没码的：生僻到 ZiDB 里都没有的字（如 迍邅 里的 迍/邅）。
local MAX_SINGLE_KEYS = 2

function M.is_single_char(ctx, ch)
    M.init(ctx)
    local codes_of = state(ctx).codes[ch]
    if not codes_of then
        return false
    end
    local sound = flow_env.sound_keys(ctx) or ""
    local has_sound = false
    for code in pairs(codes_of) do
        if sound:find(code:sub(1, 1), 1, true) then
            if #code > MAX_SINGLE_KEYS then
                return false
            end
            has_sound = true
        end
    end
    return has_sound
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
