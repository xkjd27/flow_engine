-- 键道 Flow 共享引擎 —— 用户数据跨机同步（自有文件格式）
--
-- 目标：让 pin（调序/造词）、声笔简码覆盖、次简覆盖跨机器走，且
--   * 每台机器只写自己的文件，绝不写别人的（避免云盘/别的机器写冲突）；
--   * 文件始终是「每个身份一条当前状态」，不随编辑次数增长。
--
-- 传输：
--   每个方案在用户目录维护一个纯文本文件（order 库名 + ".sync.txt"），
--   内容 = 头部注释 + 若干 payload 行（见下），是**压缩过的当前状态**
--   （每个身份一条：最新记录，或墓碑）。每次修改全量重写 + 原子替换。
--   Rime 部署/同步时会跑 backup_config_files，把用户目录顶层的 *.txt
--   复制到 <sync_dir>/<installation_id>/；别的机器 load 时扫
--   <sync_dir>/*/<同名文件> 读进来合并。远端文件只读，不写。
--
-- 记录格式（一行一条）：
--   payload = v1 <US> kind <US> identity <US> args… <US> ts <US> seq
--   US = \x1f（字段分隔；tab/换行/%/US 用 %XX 转义，所以一行不会被打断）
--   kind: pin(词,码,位次,音节) / unpin(词) / sbb(码,文本) / sbclear(码)
--         / sec(码,文本) / secclear(码)
--   版本 = (ts, seq)：ts 是墙钟毫秒（os.time + 单调毫秒补精度，
--   因为 rime_api.get_time_ms 是 steady_clock，跨机不可比），seq 是进程内
--   自增。跨机同毫秒同 seq 的极小概率情况按 payload 排序兜底，保证各机器
--   算出的 winner 一致（不需要存 installation id）。
--
-- 合并：load 时读本地文件 + 所有远端文件，每个身份（pin 看词、sbb/sec 看码）
-- 取版本最大的记录应用；删除用墓碑（unpin / sbclear / secclear），否则别的
-- 机器上旧记录会复活。合并后把本地文件重写成压缩过的 winner 集合。
-- 第一次 load 时，私有状态里有、但没有任何记录的身份会补一条当前状态
-- （bootstrap），升级后第一次同步就能把老数据带出去。
--
-- 为什么不用 Rime 的 userdb 同步通道（librime 1.16.1 的实际行为）：
--   * 快照 key 必须是「码 <TAB> 词」两段，value 会被 UserDbValue 重写成
--     c=/d=/t=，状态只能塞 key；状态一变 key 就变，而 Rime 的合并是并集、
--     没有删除语义，每次同步又是「先并所有快照再备份自己」→ 历史记录永久
--     留在快照并集里，只清自己那份快照也没用（下一轮又从别人的并回来）；
--   * 想清掉就得改别人的快照文件，会和云盘/别的机器写冲突；
--   * 私有的 ord/… / sbb/… key 不含 tab，本来就不会被同步。
--   自有文件没有这些约束，而且天然有界。

local flow_env = require("flow_env")

local M = {}

local VERSION = "v1"
local SEP = string.char(31)          -- unit separator：字段分隔
local HEADER = "# flow_engine sync v1"

local KINDS = {
    pin = { args = 3, group = "pin" },
    unpin = { args = 0, group = "pin" },
    sbb = { args = 1, group = "sbb" },
    sbclear = { args = 0, group = "sbb" },
    sec = { args = 1, group = "sec" },
    secclear = { args = 0, group = "sec" },
}

-- 转义：文件按行存，字段里不能有换行/tab；US 是我们自己的分隔符。
-- 用十进制 \31 写（Lua 5.1 兼容，方便测试脚本跑 luajit）。
local function enc(s)
    s = tostring(s or "")
    return (s:gsub("[%%\t\n\r\31]", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

local function dec(s)
    return (s:gsub("%%(%x%x)", function(h)
        return string.char(tonumber(h, 16))
    end))
end

-- 按 US 切分；保留空字段（文本为空的 sbb/sec 要靠它）
local function split_sep(s)
    local out = {}
    local start = 1
    while true do
        local i = s:find(SEP, start, true)
        if not i then
            out[#out + 1] = s:sub(start)
            break
        end
        out[#out + 1] = s:sub(start, i - 1)
        start = i + 1
    end
    return out
end

local function version_less(a, b)
    if a.ts ~= b.ts then
        return a.ts < b.ts
    end
    if a.seq ~= b.seq then
        return a.seq < b.seq
    end
    -- 跨机同毫秒同 seq 的极小概率情况：按 payload 兜底，保证确定性
    return (a.raw or "") < (b.raw or "")
end

local function user_dir()
    if rime_api and rime_api.get_user_data_dir then
        local ok, dir = pcall(rime_api.get_user_data_dir)
        if ok and type(dir) == "string" and dir ~= "" then
            return dir
        end
    end
    return "."
end

-- 墙钟毫秒。rime_api.get_time_ms 是 steady_clock（开机毫秒），跨机不可比，
-- 所以拿它只补「同一台机器内的亚秒精度」：首见时记下墙钟与单调的差，之后
-- 用单调增量加到墙钟上。没有它就退回整秒（os.time）。
local function now_ms(sy)
    if sy.now then
        return sy.now()          -- 测试可以换掉
    end
    local wall = os.time() * 1000
    if rime_api and rime_api.get_time_ms then
        local ok, mono = pcall(rime_api.get_time_ms)
        if ok and type(mono) == "number" then
            if not sy.base_mono then
                sy.base_mono = mono
                sy.base_wall = wall
            end
            return sy.base_wall + (mono - sy.base_mono)
        end
    end
    return wall
end

-- 机器标识：不再需要（记录里不存）。文件头也不写了（sync 目录的子目录名
-- 就是 installation id）。

local function payload_of(rec)
    local f = { VERSION, rec.kind, enc(rec.identity) }
    for _, a in ipairs(rec.args) do
        f[#f + 1] = a
    end
    f[#f + 1] = tostring(rec.ts)
    f[#f + 1] = tostring(rec.seq)
    return table.concat(f, SEP)
end

-- 解析一条记录；任何不合法（版本/kind/字段数/数值/空身份/pin key 不像 pin）
-- 都返回 nil —— 坏行只跳过，绝不影响别的东西。
local function parse(payload)
    if payload:find("\t", 1, true) or payload:find("\n", 1, true)
            or payload:find("\r", 1, true) then
        return nil
    end
    local f = split_sep(payload)
    if #f < 5 or f[1] ~= VERSION then
        return nil
    end
    local spec = KINDS[f[2]]
    if not spec then
        return nil
    end
    local n = #f
    local nargs = n - 5
    if nargs ~= spec.args then
        return nil
    end
    local identity = dec(f[3])
    if identity == "" then
        return nil
    end
    local ts = tonumber(f[n - 1])
    local seq = tonumber(f[n])
    if not ts or not seq then
        return nil
    end
    local args = {}
    for i = 4, 3 + nargs do
        args[#args + 1] = f[i]
    end
    local rec = {
        kind = f[2],
        identity = identity,
        args = args,
        ts = ts,
        seq = seq,
        raw = payload,
        group = spec.group .. SEP .. enc(identity),
        state = f[2] .. SEP .. table.concat(args, SEP),
    }
    if rec.kind == "pin" then
        rec.key = dec(args[1])
        rec.index = tonumber(args[2])
        rec.syl = dec(args[3])
        if rec.key == "" or rec.key:sub(1, 1) == "~"
                or not rec.key:find("|", 1, true)
                or not rec.index or rec.index < 1 then
            return nil
        end
    elseif rec.kind == "sbb" or rec.kind == "sec" then
        rec.text = dec(args[1])
    end
    return rec
end

-- ---------------- 文件读写 ----------------

local function shquote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function read_file(path)
    local f = io.open(path, "r")
    if not f then
        return nil
    end
    local text = f:read("a")
    f:close()
    return text
end

-- 原子替换：先写临时文件再 rename；Windows 上 rename 不能覆盖，先删目标
local function write_atomic(path, text)
    local tmp = path .. ".tmp"
    local f = io.open(tmp, "w")
    if not f then
        return false
    end
    f:write(text)
    f:close()
    if os.rename(tmp, path) then
        return true
    end
    os.remove(path)
    if os.rename(tmp, path) then
        return true
    end
    os.remove(tmp)
    return false
end

local function list_dir(path)
    if not io.popen then
        return nil
    end
    local cmd
    if package.config and package.config:sub(1, 1) == "\\" then
        cmd = 'dir /b "' .. tostring(path) .. '" 2>nul'
    else
        cmd = "ls -1 -- " .. shquote(path) .. " 2>/dev/null"
    end
    local ok, p = pcall(io.popen, cmd)
    if not ok or not p then
        return nil
    end
    local out = p:read("a")
    p:close()
    if not out then
        return nil
    end
    local names = {}
    for name in out:gmatch("[^\n]+") do
        names[#names + 1] = name
    end
    return names
end

-- 所有安装的快照文件路径（<sync_dir>/<id>/<同名文件>），只读
local function remote_paths(sy)
    local out = {}
    if not sy.sync_dir or not sy.file then
        return out
    end
    local base = sy.file:match("([^/\\]+)$")
    if not base then
        return out
    end
    local names = list_dir(sy.sync_dir)
    if not names then
        return out
    end
    for _, name in ipairs(names) do
        local path = sy.sync_dir .. "/" .. name .. "/" .. base
        local f = io.open(path, "r")
        if f then
            f:close()
            out[#out + 1] = path
        end
    end
    return out
end

-- 把本地文件重写成「每个身份一条 winner」的压缩状态；内容没变就不动文件
-- （避免每次 load 都刷 mtime，让云盘重复上传）。
local function save_file(st)
    local sy = st.sync
    if not sy or not sy.enabled or not sy.file then
        return false
    end
    local groups = {}
    for g in pairs(sy.winners) do
        groups[#groups + 1] = g
    end
    table.sort(groups)
    local lines = { HEADER }
    for _, g in ipairs(groups) do
        lines[#lines + 1] = sy.winners[g].raw
    end
    local text = table.concat(lines, "\n") .. "\n"
    if sy.last_saved == text then
        return true
    end
    if write_atomic(sy.file, text) then
        sy.last_saved = text
        return true
    end
    if log and log.warning and not sy.save_warned then
        sy.save_warned = true
        log.warning("flow_sync: 写不了同步文件 " .. tostring(sy.file))
    end
    return false
end

-- ---------------- 记录构造 ----------------

-- 构造一条记录（不落盘）。state 一样就直接返回 nil（去重：没变化不写）。
local function make_record(st, kind, identity, args)
    local sy = st.sync
    if not sy or not sy.enabled or sy.suppress then
        return nil
    end
    identity = tostring(identity or "")
    if identity == "" then
        return nil
    end
    local spec = KINDS[kind]
    if not spec then
        return nil
    end
    local fields = {}
    for i, a in ipairs(args) do
        fields[i] = enc(a)
    end
    local group = spec.group .. SEP .. enc(identity)
    local state = kind .. SEP .. table.concat(fields, SEP)
    local old = sy.winners[group]
    if old and old.state == state then
        return nil
    end
    -- 版本必须严格大于旧 winner（防时钟回拨；正常情况下 ts 已经更大）
    sy.seq = sy.seq + 1
    local v = { ts = now_ms(sy), seq = sy.seq }
    if old and not version_less(old, v) then
        v.ts = old.ts
        sy.seq = math.max(sy.seq, old.seq + 1)
        v.seq = sy.seq
        if not version_less(old, v) then
            v.ts = old.ts + 1
        end
    end
    local rec = {
        kind = kind,
        identity = identity,
        args = fields,
        ts = v.ts,
        seq = v.seq,
        group = group,
        state = state,
    }
    rec.raw = payload_of(rec)
    return rec
end

local function emit(st, kind, identity, args)
    local rec = make_record(st, kind, identity, args)
    if not rec then
        return false
    end
    st.sync.winners[rec.group] = rec
    save_file(st)
    return true
end

-- ---------------- 状态 ----------------

function M.new_state(flow, name)
    local sync_dir
    if rime_api and rime_api.get_sync_dir then
        local ok, v = pcall(rime_api.get_sync_dir)
        if ok and type(v) == "string" and v ~= "" then
            sync_dir = v
        end
    end
    local file
    if name and name ~= "" then
        file = user_dir() .. "/" .. name .. ".sync.txt"
    end
    return {
        enabled = flow_env.get_bool(flow, "flow_order/sync", true),
        file = file,
        sync_dir = sync_dir,
        last_saved = file and read_file(file) or nil,
        winners = {},          -- group -> 最新记录
        seq = 0,
    }
end

-- ---------------- 记录入口（flow_order 的修改动作调用） ----------------

function M.record_pin(st, key, text, index, syl)
    if type(key) ~= "string" or not key:find("|", 1, true)
            or key:sub(1, 1) == "~" then
        return false
    end
    return emit(st, "pin", text, { key, tostring(index or 1), syl or "" })
end

function M.record_unpin(st, text)
    return emit(st, "unpin", text, {})
end

function M.record_shengbi(st, code, text)
    return emit(st, "sbb", code, { text or "" })
end

function M.record_shengbi_clear(st, code)
    return emit(st, "sbclear", code, {})
end

function M.record_secondary(st, code, text)
    return emit(st, "sec", code, { text or "" })
end

function M.record_secondary_clear(st, code)
    return emit(st, "secclear", code, {})
end

-- ---------------- bootstrap（老数据第一次补记录） ----------------

-- 私有状态里有、但还没有记录的身份，补一条当前状态（不落盘，reconcile 最后
-- 统一保存）。
function M.bootstrap(st)
    local sy = st.sync
    if not sy or not sy.enabled then
        return 0
    end
    local function has(kind, identity)
        return sy.winners[KINDS[kind].group .. SEP .. enc(identity)] ~= nil
    end
    local function put(kind, identity, args)
        local rec = make_record(st, kind, identity, args)
        if rec then
            sy.winners[rec.group] = rec
            return 1
        end
        return 0
    end
    local n = 0
    local seen = {}
    for key, list in pairs(st.order or {}) do
        if key:find("|", 1, true) and key:sub(1, 1) ~= "~" then
            for i, text in ipairs(list) do
                if text ~= "" and not seen[text] then
                    seen[text] = true
                    if not has("pin", text) then
                        local syls = st.syllables and st.syllables[key]
                        n = n + put("pin", text,
                                    { key, tostring(i), syls and syls[text] or "" })
                    end
                end
            end
        end
    end
    for code, text in pairs(st.shengbi or {}) do
        if not has("sbb", code) then
            n = n + put("sbb", code, { text })
        end
    end
    for code, text in pairs(st.secondary or {}) do
        if not has("sec", code) then
            n = n + put("sec", code, { text })
        end
    end
    return n
end

-- ---------------- 合并 ----------------

-- word -> {key, index, count} 索引（pin 身份），reconcile 时建一次。
-- count = 这个词出现在几个 pin key 里；只有恰好 1 处才算「状态一致」
-- （同一个词挂在多个 key 是异常状态，必须 apply 去重）。
local function build_pin_index(st)
    local idx = {}
    for key, list in pairs(st.order or {}) do
        if key:find("|", 1, true) and key:sub(1, 1) ~= "~" then
            for i, text in ipairs(list) do
                local e = idx[text]
                if not e then
                    idx[text] = { key = key, index = i, count = 1 }
                else
                    e.count = e.count + 1
                end
            end
        end
    end
    return idx
end

-- 私有状态现在是不是已经是这条记录的状态？
-- 是的话就不用 apply —— 大多数 load 时状态已经一致，apply 要 remove_pin
-- 扫全表 + 写库，几千个身份就是 O(n²)，跳过可以省掉这一大块。
-- 对不上（远端有更新、或者私有库被清空/恢复过）就必须 apply，不会丢状态。
local function state_matches(st, idx, rec)
    if rec.kind == "pin" then
        local at = idx[rec.identity]
        if not at or at.count ~= 1 or at.key ~= rec.key
                or at.index ~= rec.index then
            return false
        end
        local syls = st.syllables and st.syllables[rec.key]
        local cur = syls and syls[rec.identity] or ""
        return (rec.syl or "") == (cur or "")
    elseif rec.kind == "unpin" then
        return idx[rec.identity] == nil
    elseif rec.kind == "sbb" then
        local cur = st.shengbi and st.shengbi[rec.identity]
        return cur == rec.text
    elseif rec.kind == "sbclear" then
        return not st.shengbi or st.shengbi[rec.identity] == nil
    elseif rec.kind == "sec" then
        local cur = st.secondary and st.secondary[rec.identity]
        return cur == rec.text
    elseif rec.kind == "secclear" then
        return not st.secondary or st.secondary[rec.identity] == nil
    end
    return false
end

-- apply 之后重建 pin 索引（apply 可能挪动同一个 key 里其他词的位置）。
-- 只在 pin/unpin 应用后重建；常见情况（状态全一致）一次都不用重建。

-- 读本地 + 所有远端文件 → 每个身份取最新 → 按版本升序 apply → bootstrap →
-- 把本地文件重写成压缩状态。apply(rec) 由 flow_order 提供。
-- 应用期间 suppress = true，flow_order 的修改动作不会再写记录/文件。
function M.reconcile(st, apply)
    local sy = st.sync
    if not sy or not sy.enabled then
        return 0
    end
    local all = {}
    local function collect(path)
        local text = read_file(path)
        if not text then
            return
        end
        for line in text:gmatch("[^\n]+") do
            if line ~= "" and line:sub(1, 1) ~= "#" then
                local rec = parse(line)
                if rec then
                    all[#all + 1] = rec
                elseif log and log.warning then
                    log.warning("flow_sync: 忽略无法解析的记录行：" .. line)
                end
            end
        end
    end
    if sy.file then
        collect(sy.file)
    end
    for _, path in ipairs(remote_paths(sy)) do
        collect(path)
    end

    local groups = {}
    for _, rec in ipairs(all) do
        local old = groups[rec.group]
        if not old or version_less(old, rec) then
            groups[rec.group] = rec
        end
    end
    local winners = {}
    for _, rec in pairs(groups) do
        winners[#winners + 1] = rec
    end
    table.sort(winners, version_less)

    local idx = build_pin_index(st)
    sy.suppress = true
    local applied = 0
    for _, rec in ipairs(winners) do
        if state_matches(st, idx, rec) then
            -- 状态已经一致：跳过
        else
            local ok, err = pcall(apply, rec)
            if not ok and log and log.error then
                log.error("flow_sync: 应用 " .. rec.kind .. " 记录失败："
                          .. tostring(err))
            end
            if rec.kind == "pin" or rec.kind == "unpin" then
                idx = build_pin_index(st)
            end
            applied = applied + 1
        end
    end
    sy.suppress = false
    sy.winners = groups

    local booted = M.bootstrap(st)
    save_file(st)
    if log and log.info then
        log.info("flow_sync: 合并 " .. tostring(#winners) .. " 条记录（实际应用 "
                 .. tostring(applied) .. " 条），bootstrap " .. tostring(booted))
    end
    return #winners
end

return M
