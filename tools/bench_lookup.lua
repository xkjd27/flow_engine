-- 查表结构对比：字典 vs 二分
--
--   lua tools/bench_lookup.lua <danzi.dict.yaml> [shape.dict.yaml] [冷查样本数]
--
-- 两种结构都从同一份单字表（+可选的形码表）建起来，都要能回答「这个字有
-- 哪些码、各自权重多少」：
--   A 字典：codes[字] = {码 = 权重}   —— 建表时把每个字都解析好
--   B 二分：chars[i]（排好序） + codes[i]（"码:权重 码:权重"）—— 查的时候
--           二分定位 + 现场解析
-- 关注三件事：建表耗时、常驻内存、冷查/热查速度，以及「查 N 个字」的总时间
-- （N = 一次输入会话里大致会碰到的不同候选字数）。
--
-- 结论（见下）不是「哪个绝对快」，而是：
--   * 字表只有 8394 字，字典的建表开销（~20-40 ms，主要花在读文件上）
--     和内存（~1.6 MB）都很小；
--   * 二分省内存但要现场解析，冷查慢一个数量级；会话里真正会碰到的不同字
--     通常只有几百个，两者总时间差在毫秒级。

local function now() return os.clock() end
local function mem() collectgarbage("collect") return collectgarbage("count") end

local danzi = arg[1]
local shape = arg[2]
local sample = tonumber(arg[3] or "500")

local function read_rows(path)
    local rows = {}
    local f = assert(io.open(path, "r"))
    local buf = f:read("a")
    f:close()
    for ch, code, w in buf:gmatch("([^\t\n]+)\t([^\t\n]+)\t([%d%.]+)\n") do
        rows[#rows + 1] = { ch = ch, code = code, w = tonumber(w) or 0 }
    end
    return rows, buf
end

local rows, raw = read_rows(danzi)
local shape_rows = shape and read_rows(shape) or {}

-- 确定性打乱（按字做个小 hash），模拟「候选里冒出来的字是乱的」
local function order_key(ch)
    local h = 5381
    for i = 1, #ch do
        h = (h * 33 + ch:byte(i)) % 4294967296
    end
    return h
end

local function shuffled(rows)
    local idx = {}
    for i = 1, #rows do
        idx[i] = i
    end
    table.sort(idx, function(a, b)
        local ka, kb = order_key(rows[a].ch), order_key(rows[b].ch)
        if ka ~= kb then
            return ka < kb
        end
        return a < b
    end)
    return idx
end

-- ---------------- A：字典 ----------------
local function build_dict()
    local dict = {}
    local function add(rs)
        for _, r in ipairs(rs) do
            local t = dict[r.ch]
            if not t then
                t = {}
                dict[r.ch] = t
            end
            if r.w > (t[r.code] or -1) then
                t[r.code] = r.w
            end
        end
    end
    add(rows)
    add(shape_rows)
    return dict
end

local function dict_lookup(dict, ch)
    local t = dict[ch]
    if not t then
        return nil
    end
    local out = {}
    for code, w in pairs(t) do
        out[#out + 1] = { code = code, w = w }
    end
    table.sort(out, function(a, b)
        if a.w ~= b.w then
            return a.w > b.w
        end
        return a.code < b.code
    end)
    return out
end

-- ---------------- B：二分 ----------------
local function build_sorted()
    -- 同一个字可能在单字表和形码表里都出现：先按字聚合，再排序
    local acc = {}
    local function add(rs)
        for _, r in ipairs(rs) do
            local t = acc[r.ch]
            if not t then
                t = {}
                acc[r.ch] = t
            end
            if r.w > (t[r.code] or -1) then
                t[r.code] = r.w
            end
        end
    end
    add(rows)
    add(shape_rows)
    local chars = {}
    for ch in pairs(acc) do
        chars[#chars + 1] = ch
    end
    table.sort(chars)
    local codes = {}
    for i, ch in ipairs(chars) do
        local parts = {}
        for code, w in pairs(acc[ch]) do
            parts[#parts + 1] = code .. ":" .. tostring(w)
        end
        codes[i] = table.concat(parts, " ")
    end
    return chars, codes
end

local function sorted_lookup(chars, codes, ch)
    local lo, hi = 1, #chars
    while lo <= hi do
        local mid = (lo + hi) // 2
        local c = chars[mid]
        if c == ch then
            local out = {}
            for code, w in codes[mid]:gmatch("([^: ]+):([%d%.]+)") do
                out[#out + 1] = { code = code, w = tonumber(w) }
            end
            table.sort(out, function(a, b)
                if a.w ~= b.w then
                    return a.w > b.w
                end
                return a.code < b.code
            end)
            return out
        elseif c < ch then
            lo = mid + 1
        else
            hi = mid - 1
        end
    end
    return nil
end

-- ---------------- 跑 ----------------
local function bench(name, build, lookup)
    collectgarbage("collect")
    local m0 = mem()
    local t0 = now()
    local s1, s2 = build()
    local build_ms = (now() - t0) * 1000
    local mem_kb = mem() - m0

    -- 全字表的冷查（打乱顺序）
    local idx = shuffled(rows)
    t0 = now()
    local hits = 0
    for _, i in ipairs(idx) do
        if lookup(s1, s2, rows[i].ch) then
            hits = hits + 1
        end
    end
    local cold_total = (now() - t0) * 1000
    local cold_us = cold_total / #idx * 1000

    -- 一次会话量级（sample 个不同字）：只算「建表 + 查这些字」
    local sess_total = build_ms
    do
        local t = now()
        for i = 1, math.min(sample, #idx) do
            lookup(s1, s2, rows[idx[i]].ch)
        end
        sess_total = sess_total + (now() - t) * 1000
    end

    -- 热查：字典本身 + 各模块自己的 char_cache；这里量一次缓存命中
    local cache = {}
    for i = 1, math.min(sample, #idx) do
        cache[rows[idx[i]].ch] = lookup(s1, s2, rows[idx[i]].ch)
    end
    local hot_n = 0
    t0 = now()
    for i = 1, 200000 do
        if cache[rows[idx[(i % sample) + 1]].ch] then
            hot_n = hot_n + 1
        end
    end
    local hot_ns = (now() - t0) / 200000 * 1e9

    print(string.format(
        "%-8s 建表 %6.1f ms | 常驻 %6.1f KB | 冷查 %6.2f us/字 | 查遍全表 %6.1f ms"
        .. " | %4d 字会话总耗时 %6.1f ms | 缓存命中 %.0f ns",
        name, build_ms, mem_kb, cold_us, cold_total, sample, sess_total, hot_ns))
end

print(string.format("数据：%d 行单字表%s（%d 字）",
    #rows, shape and (" + " .. #shape_rows .. " 行形码表"), (function()
        local n = {}
        for _, r in ipairs(rows) do n[r.ch] = true end
        local c = 0
        for _ in pairs(n) do c = c + 1 end
        return c
    end)()))
bench("字典", function()
    local d = build_dict()
    return d, nil
end, dict_lookup)
bench("二分", function()
    local c, v = build_sorted()
    return c, v
end, sorted_lookup)
