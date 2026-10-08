-- flow_engine 同步测试（不依赖 librime）
--
-- 用假 LevelDb 跑真实引擎代码（flow_env / flow_order / flow_sync）：
--   * order 库用假 LevelDb（只关心内存状态，以及「不再往 userdb 写记录」）；
--   * 同步走真实文件：引擎写 <user>/<db>.sync.txt，测试用 sync_out() 模拟
--     Rime 的 backup_config_files（把本地文件拷到 <sync_dir>/<id>/），
--     load 时引擎会自己扫 <sync_dir>/*/ 读远端文件合并。
-- 多台"机器"在同一个进程里用不同 schema_id + 不同 user dir 模拟。
--
-- 用法：luajit test_sync.lua [engine_lua_dir]

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

-- ---------- stub：时间 ----------
_G.__wall = 1000            -- os.time() 秒
_G.__mono = 0               -- rime_api.get_time_ms()（steady clock 毫秒）
os.time = function() return _G.__wall end

-- ---------- 机器 ----------
local ROOT = "/tmp/flow_sync_test"
local DB = "testdict.order"
local MACHINES = {
    A = { dir = ROOT .. "/userA", id = "machine-A" },
    B = { dir = ROOT .. "/userB", id = "machine-B" },
    C = { dir = ROOT .. "/userC", id = "machine-C" },
}
_G.__sync_dir = ROOT .. "/sync"

local function use(m)
    _G.rime_api = {
        get_user_data_dir = function() return m.dir end,
        get_shared_data_dir = function() return nil end,
        get_user_id = function() return m.id end,
        get_time_ms = function() return _G.__mono end,
        get_sync_dir = function() return _G.__sync_dir end,
    }
end

-- ---------- 引擎装载 ----------
local flow_env = require("flow_env")
local order = require("flow_order")

local function make_flow(schema_id, opts)
    opts = opts or {}
    local config = {
        get_string = function(_, k)
            if k == "translator/dictionary" then return opts.dict or "testdict" end
            if k == "schema/schema_id" then return schema_id end
            if k == "flow_engine/sound_keys" then
                return "bcdfghjklmnpqrstuwxyz;"
            end
            if k == "flow_engine/shape_keys" then return "aeiov" end
            if k == "flow_order/backend" then return opts.backend end
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
            schema = { schema_id = schema_id, config = config },
            context = {},
        },
        name_space = schema_id,
    }
    local flow = flow_env.attach(env)
    order.init(flow)
    return flow, env
end

local function unload(flow, env)
    order.close(flow)
    flow_env.release(env)
end

-- ---------- 文件工具 ----------
local function read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local text = f:read("a")
    f:close()
    return text
end

local function write_file(path, text)
    local f = io.open(path, "w")
    if not f then return false end
    f:write(text or "")
    f:close()
    return true
end

local function hash(text)
    local h = 5381
    for i = 1, #(text or "") do
        h = (h * 33 + text:byte(i)) % 4294967296
    end
    return h
end

local function local_path(m)
    return m.dir .. "/" .. DB .. ".sync.txt"
end

local function remote_path(m)
    return _G.__sync_dir .. "/" .. m.id .. "/" .. DB .. ".sync.txt"
end

local function remote_text(m)
    return read_file(remote_path(m))
end

-- 模拟 Rime 的 backup_config_files：本地同步文件 -> <sync_dir>/<id>/
local function sync_out(m)
    os.execute("mkdir -p " .. _G.__sync_dir .. "/" .. m.id)
    local text = read_file(local_path(m))
    if text then
        write_file(remote_path(m), text)
    end
end

-- 本地同步文件里的记录行（去掉头/注释）
local function record_lines(m)
    local text = read_file(local_path(m))
    local out = {}
    if text then
        for line in text:gmatch("[^\n]+") do
            if line ~= "" and line:sub(1, 1) ~= "#" then
                out[#out + 1] = line
            end
        end
    end
    return out
end

-- order 库里有没有残留的 fsync 记录（应该永远 0）
local function db_fsync_keys(m)
    local store = store_of(m.dir, DB)
    local out = {}
    for k in pairs(store.kv) do
        if k:sub(1, 6) == "fsync " then
            out[#out + 1] = k
        end
    end
    return out
end

local function private_keys(m, prefix)
    local store = store_of(m.dir, DB)
    local out = {}
    for k in pairs(store.kv) do
        if k:sub(1, #prefix) == prefix then
            out[#out + 1] = k
        end
    end
    table.sort(out)
    return out
end

local function put_raw(m, key, value)
    store_of(m.dir, DB).kv[key] = value or ""
end

-- userdb 快照导出（用来断言「我们的记录不再走 userdb」）
local function rime_export(m, db_name)
    local store = store_of(m.dir, db_name)
    local lines = { "# Rime user dictionary", "#@/db_name\t" .. db_name }
    local keys = {}
    for k in pairs(store.kv) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do
        local row = {}
        local start = 1
        while true do
            local i = k:find("\t", start, true)
            if not i then row[#row + 1] = k:sub(start); break end
            row[#row + 1] = k:sub(start, i - 1)
            start = i + 1
        end
        if #row == 2 and row[1] ~= "" and row[2] ~= "" then
            lines[#lines + 1] = row[1] .. "\t" .. row[2] .. "\t"
                .. (store.kv[k] or "")
        end
    end
    return table.concat(lines, "\n") .. "\n"
end

local function reset()
    _G.__stores = {}
    _G.__open_dbs = {}
    _G.__updates = 0
    _G.__sync_dir = ROOT .. "/sync"
    -- 只清自己的测试子目录，别动整个 /tmp/flow_sync_test
    os.execute("rm -rf " .. ROOT .. "/userA " .. ROOT .. "/userB "
               .. ROOT .. "/userC " .. ROOT .. "/sync")
    os.execute("mkdir -p " .. ROOT .. "/userA " .. ROOT .. "/userB "
               .. ROOT .. "/userC " .. ROOT .. "/sync")
end

-- ============================================================
print("== 1. 记录格式：自有文件、压缩、不再走 userdb ==")
do
    reset()
    use(MACHINES.A)
    local flow, env = make_flow("t1")
    order.insert(flow, "wumk|", "我们", 1)
    order.insert(flow, "wumk|k", "问", 2, "wen")
    order.set_shengbi(flow, ";a", "只能")
    order.set_secondary(flow, "z", "在")
    local lines = record_lines(MACHINES.A)
    eq(#lines, 4, "4 个身份各一条记录（压缩）")
    for _, line in ipairs(lines) do
        eq(line:sub(1, 3), "v1" .. string.char(31), "记录行是 v1 payload")
    end
    local text = read_file(local_path(MACHINES.A))
    ok(text:find("^# flow_engine sync v1") ~= nil, "有文件头")
    eq(#db_fsync_keys(MACHINES.A), 0, "order 库里没有 fsync 记录")
    local snap = rime_export(MACHINES.A, DB)
    ok(not snap:find("fsync ", 1, true), "userdb 快照里没有我们的记录")
    ok(not snap:find("ord/", 1, true), "userdb 快照里没有私有 key")
    unload(flow, env)
end

print("== 2. bootstrap：老数据第一次补记录、重载不重复 ==")
do
    reset()
    use(MACHINES.A)
    local flow, env = make_flow("t2")
    order.insert(flow, "wumk|", "我们", 1)
    unload(flow, env)
    os.remove(local_path(MACHINES.A))          -- 模拟升级前没有同步文件
    use(MACHINES.A)
    local flow2, env2 = make_flow("t2")
    eq(#record_lines(MACHINES.A), 1, "bootstrap 补出 1 条记录")
    unload(flow2, env2)
    local flow3, env3 = make_flow("t2")
    eq(#record_lines(MACHINES.A), 1, "再次 load 不重复写")
    eq(order.get(flow3, "wumk|")[1], "我们", "状态保持")
    unload(flow3, env3)
end

print("== 3. A→B 同步：pin / sbb / secondary 都过去，远端文件只读 ==")
do
    reset()
    use(MACHINES.A)
    local fa, ea = make_flow("t3a")
    order.insert(fa, "wumk|", "我们", 1)
    order.set_shengbi(fa, ";a", "只能")
    order.set_secondary(fa, "z", "在")
    unload(fa, ea)
    sync_out(MACHINES.A)
    local before = remote_text(MACHINES.A)
    ok(before ~= nil, "A 的同步文件被拷进 sync 目录")

    use(MACHINES.B)
    local fb, eb = make_flow("t3b")
    eq(order.get(fb, "wumk|")[1], "我们", "pin 同步到 B")
    eq(order.get_shengbi(fb, ";a"), "只能", "sbb 同步到 B")
    eq(order.get_secondary(fb, "z"), "在", "secondary 同步到 B")
    unload(fb, eb)
    eq(remote_text(MACHINES.A), before, "B 没有改 A 的远端文件")
    use(MACHINES.B)
    local fb2, eb2 = make_flow("t3b")
    eq(order.get(fb2, "wumk|")[1], "我们", "重载后 pin 仍在")
    eq(order.get_shengbi(fb2, ";a"), "只能", "重载后 sbb 仍在")
    unload(fb2, eb2)
end

print("== 4. 冲突：按 (ts, machine) 取最新 ==")
do
    reset()
    _G.__wall, _G.__mono = 1000, 0
    use(MACHINES.A)
    local fa, ea = make_flow("t4a")
    order.insert(fa, "wumk|", "我们", 1)          -- r1
    unload(fa, ea)
    sync_out(MACHINES.A)

    use(MACHINES.B)
    local fb, eb = make_flow("t4b")
    eq(order.get(fb, "wumk|")[1], "我们", "B 先拿到 A 的 pin")
    _G.__wall, _G.__mono = 1001, 0
    order.insert(fb, "wumk|k", "我们", 1)         -- r2（更晚）
    unload(fb, eb)
    sync_out(MACHINES.B)

    use(MACHINES.A)
    local fa2, ea2 = make_flow("t4a")
    ok(order.get(fa2, "wumk|") == nil, "旧的 key 被清掉")
    eq(order.get(fa2, "wumk|k")[1], "我们", "A 采用 B 更晚的 pin")
    eq(#record_lines(MACHINES.A), 1, "A 的本地文件仍然压缩")
    unload(fa2, ea2)

    -- 旧远端（第三方安装的老文件）不能翻盘
    local old = remote_text(MACHINES.A)           -- A 自己那份还是 r1
    os.execute("mkdir -p " .. _G.__sync_dir .. "/machine-D")
    write_file(_G.__sync_dir .. "/machine-D/" .. DB .. ".sync.txt", old)
    use(MACHINES.A)
    local fa3, ea3 = make_flow("t4a")
    eq(order.get(fa3, "wumk|k")[1], "我们", "旧记录不翻盘")
    ok(order.get(fa3, "wumk|") == nil, "旧 key 不复活")
    unload(fa3, ea3)
    eq(read_file(_G.__sync_dir .. "/machine-D/" .. DB .. ".sync.txt"), old,
       "第三方的老文件也没被动过")
end

print("== 5. 墓碑：unpin / sbclear / secclear 会传播 ==")
do
    reset()
    _G.__wall, _G.__mono = 2000, 0
    use(MACHINES.A)
    local fa, ea = make_flow("t5a")
    order.insert(fa, "wumk|", "我们", 1)
    order.set_shengbi(fa, ";a", "只能")
    order.set_secondary(fa, "z", "在")
    unload(fa, ea)
    sync_out(MACHINES.A)
    local old_pin = remote_text(MACHINES.A)       -- 旧状态（含 pin）

    use(MACHINES.B)
    local fb, eb = make_flow("t5b")
    eq(order.get(fb, "wumk|")[1], "我们", "B 拿到 pin")
    unload(fb, eb)

    _G.__wall, _G.__mono = 2001, 0
    use(MACHINES.A)
    local fa2, ea2 = make_flow("t5a")
    order.remove_word(fa2, "我们")
    order.clear_shengbi(fa2, ";a")
    order.clear_secondary(fa2, "z")
    unload(fa2, ea2)
    sync_out(MACHINES.A)

    use(MACHINES.B)
    local fb2, eb2 = make_flow("t5b")
    ok(order.get(fb2, "wumk|") == nil, "B 的 pin 被墓碑删掉")
    ok(order.get_shengbi(fb2, ";a") == nil, "B 的 sbb 覆盖被清掉")
    ok(order.get_secondary(fb2, "z") == nil, "B 的 secondary 覆盖被清掉")
    unload(fb2, eb2)

    -- 再把旧状态（含 pin）塞给一个第三方安装，墓碑必须压住旧 pin
    os.execute("mkdir -p " .. _G.__sync_dir .. "/machine-D")
    write_file(_G.__sync_dir .. "/machine-D/" .. DB .. ".sync.txt", old_pin)
    use(MACHINES.A)
    local fa3, ea3 = make_flow("t5a")
    ok(order.get(fa3, "wumk|") == nil, "旧 pin 不会从旧文件复活")
    ok(order.get_shengbi(fa3, ";a") == nil, "旧 sbb 不会复活")
    unload(fa3, ea3)
end

print("== 6. 幂等：没有新编辑时 load 不改本地文件 ==")
do
    reset()
    _G.__wall, _G.__mono = 3000, 0
    use(MACHINES.B)
    local fb, eb = make_flow("t6b")
    order.insert(fb, "abc|", "测试", 1)
    unload(fb, eb)
    sync_out(MACHINES.B)
    local before = read_file(local_path(MACHINES.B))
    use(MACHINES.B)
    local fb2, eb2 = make_flow("t6b")
    unload(fb2, eb2)
    eq(read_file(local_path(MACHINES.B)), before, "load 后本地文件不变")
    eq(remote_text(MACHINES.B), before, "远端文件也不变")
end

print("== 7. 损坏行：跳过、不崩、好记录照常 ==")
do
    reset()
    _G.__wall, _G.__mono = 4000, 0
    use(MACHINES.A)
    local fa, ea = make_flow("t7a")
    order.insert(fa, "wumk|", "我们", 1)
    unload(fa, ea)
    -- 往本地文件塞坏行
    local bad = {
        "",
        "完全不是记录",
        "v9" .. string.char(31) .. "pin",
        "v1" .. string.char(31) .. "unknown" .. string.char(31) .. "词",
        "v1" .. string.char(31) .. "pin" .. string.char(31) .. "" .. string.char(31) .. "wumk|",
        "v1" .. string.char(31) .. "pin" .. string.char(31) .. "词" .. string.char(31) .. "~recent",
        "v1" .. string.char(31) .. "pin" .. string.char(31) .. "词" .. string.char(31) .. "novert",
        "v1" .. string.char(31) .. "pin" .. string.char(31) .. "词" .. string.char(31) .. "wumk|"
            .. string.char(31) .. "x" .. string.char(31) .. "" .. string.char(31) .. "1"
            .. string.char(31) .. "m" .. string.char(31) .. "1",
        "v1" .. string.char(31) .. "pin" .. string.char(31) .. "词" .. string.char(31) .. "wumk|"
            .. string.char(31) .. "1" .. string.char(31) .. "" .. string.char(31) .. "1"
            .. string.char(31) .. "m",
        "v1" .. string.char(31) .. "pin" .. string.char(31) .. "词" .. string.char(31) .. "wumk|"
            .. string.char(31) .. "1" .. string.char(31) .. "" .. string.char(31) .. "abc"
            .. string.char(31) .. "m" .. string.char(31) .. "1",
    }
    local f = io.open(local_path(MACHINES.A), "a")
    for _, line in ipairs(bad) do
        f:write(line, "\n")
    end
    f:close()
    -- 再塞一条坏记录到一个远端文件里 + 一条好记录
    os.execute("mkdir -p " .. _G.__sync_dir .. "/machine-D")
    write_file(_G.__sync_dir .. "/machine-D/" .. DB .. ".sync.txt",
               "fsync 只有一段\n"
               .. "v1" .. string.char(31) .. "pin" .. string.char(31) .. "好词"
               .. string.char(31) .. "zzz|" .. string.char(31) .. "1"
               .. string.char(31) .. "" .. string.char(31) .. "1"
               .. string.char(31) .. "1" .. "\n")
    use(MACHINES.A)
    local fa2, ea2 = make_flow("t7a")
    eq(order.get(fa2, "wumk|")[1], "我们", "好记录照常应用")
    eq(order.get(fa2, "zzz|")[1], "好词", "远端好记录也应用")
    ok(order.get(fa2, "~recent") == nil, "坏 pin key（~recent）没进 order")
    eq(#record_lines(MACHINES.A), 2, "本地文件重写后只剩好记录")
    unload(fa2, ea2)
end

print("== 8. 特殊字符：tab/换行/%/US/emoji ==")
do
    reset()
    _G.__wall, _G.__mono = 5000, 0
    use(MACHINES.A)
    local fa, ea = make_flow("t8a")
    local weird = "词%1\t带制表" .. string.char(31) .. "带US\n带换行😀"
    order.insert(fa, "xyz|", weird, 1)
    order.set_shengbi(fa, ";%", weird)
    order.set_secondary(fa, "q" .. string.char(31) .. "q", weird)
    unload(fa, ea)
    sync_out(MACHINES.A)
    use(MACHINES.B)
    local fb, eb = make_flow("t8b")
    eq(order.get(fb, "xyz|")[1], weird, "含特殊字符的词同步过去")
    eq(order.get_shengbi(fb, ";%"), weird, "含特殊字符的 sbb 同步过去")
    eq(order.get_secondary(fb, "q" .. string.char(31) .. "q"), weird,
       "含特殊字符的 secondary 同步过去")
    unload(fb, eb)
end

print("== 9. 同一毫秒、同一台机器（seq 定序） ==")
do
    reset()
    _G.__wall, _G.__mono = 6000, 0
    use(MACHINES.A)
    local fa, ea = make_flow("t9a")
    order.insert(fa, "aaa|", "一", 1)     -- seq=1
    order.insert(fa, "aaa|k", "一", 1)    -- seq=2（同 ts）
    unload(fa, ea)
    sync_out(MACHINES.A)
    use(MACHINES.B)
    local fb, eb = make_flow("t9b")
    ok(order.get(fb, "aaa|") == nil, "同 ts 时 seq 大的赢（旧 key 不在）")
    eq(order.get(fb, "aaa|k")[1], "一", "同 ts 时 seq 大的赢")
    unload(fb, eb)
end

print("== 10. 时钟回拨：新记录仍然压过旧 winner ==")
do
    reset()
    _G.__wall, _G.__mono = 7000, 0
    use(MACHINES.A)
    local fa, ea = make_flow("t10a")
    order.insert(fa, "bbb|", "词", 1)
    unload(fa, ea)
    _G.__wall, _G.__mono = 7000 - 600, 0      -- 回拨 10 分钟
    use(MACHINES.A)
    local fa2, ea2 = make_flow("t10a")
    order.insert(fa2, "bbb|k", "词", 1)
    unload(fa2, ea2)
    use(MACHINES.A)
    local fa3, ea3 = make_flow("t10a")
    eq(order.get(fa3, "bbb|k")[1], "词", "回拨后的新编辑仍然生效")
    ok(order.get(fa3, "bbb|") == nil, "回拨后旧 pin 被换掉")
    unload(fa3, ea3)
end

print("== 11. txt 后端：同步也能用 ==")
do
    reset()
    _G.__wall, _G.__mono = 8000, 0
    use(MACHINES.A)
    local flow, env = make_flow("t11", { backend = "txt" })
    order.insert(flow, "txt|", "文本", 1)
    ok(order.get(flow, "txt|")[1] == "文本", "txt 后端照常工作")
    ok(read_file(MACHINES.A.dir .. "/" .. DB .. ".txt") ~= nil, "txt 存储文件写了")
    eq(#record_lines(MACHINES.A), 1, "txt 后端也写同步记录")
    unload(flow, env)
    sync_out(MACHINES.A)
    use(MACHINES.B)
    local fb, eb = make_flow("t11b")
    eq(order.get(fb, "txt|")[1], "文本", "txt 后端的状态也能同步过去")
    unload(fb, eb)
end

print("== 12. 合并期间不写新记录（suppress） ==")
do
    reset()
    _G.__wall, _G.__mono = 9000, 0
    use(MACHINES.A)
    local fa, ea = make_flow("t12a")
    order.insert(fa, "ccc|", "甲", 1)
    unload(fa, ea)
    sync_out(MACHINES.A)
    local before = remote_text(MACHINES.A)
    use(MACHINES.B)
    local fb, eb = make_flow("t12b")      -- 合并 + bootstrap
    eq(order.get(fb, "ccc|")[1], "甲", "合并结果正确")
    eq(#record_lines(MACHINES.B), 1, "B 只写了合并后的记录，没有重复")
    unload(fb, eb)
    eq(remote_text(MACHINES.A), before, "A 的远端文件没被改")
end

print("== 13. 私有数据安全：pin 库/特殊键不被同步记录污染 ==")
do
    reset()
    _G.__wall, _G.__mono = 10000, 0
    use(MACHINES.A)
    local fa, ea = make_flow("t13a")
    order.touch_recent(fa, "造的词")
    order.insert(fa, "ddd|", "钉", 1)
    unload(fa, ea)
    local priv = private_keys(MACHINES.A, "ord/")
    sync_out(MACHINES.A)
    use(MACHINES.A)
    local fa2, ea2 = make_flow("t13a")
    eq(order.get(fa2, "ddd|")[1], "钉", "pin 还在")
    eq(order.recent(fa2)[1], "造的词", "~recent 还在")
    eq(#private_keys(MACHINES.A, "ord/"), #priv, "私有 key 数不变")
    unload(fa2, ea2)
end

print("== 14. 私有命名空间保护：ord/ 下带 tab 的 key 被忽略并清掉 ==")
do
    reset()
    _G.__wall, _G.__mono = 11000, 0
    use(MACHINES.A)
    local fa, ea = make_flow("t14a")
    order.insert(fa, "wumk|", "我们", 1)
    unload(fa, ea)
    put_raw(MACHINES.A, "ord/evil \tpin", "假的")
    put_raw(MACHINES.A, "sbb/evil \t假", "假的")
    use(MACHINES.A)
    local fa2, ea2 = make_flow("t14a")
    ok(order.get(fa2, "evil \tpin") == nil, "ord/ 下带 tab 的伪造 key 没进 order")
    ok(order.get_shengbi(fa2, "evil \t假") == nil, "sbb/ 下带 tab 的伪造 key 没进覆盖")
    eq(order.get(fa2, "wumk|")[1], "我们", "正常 pin 不受影响")
    local store = store_of(MACHINES.A.dir, DB)
    ok(store.kv["ord/evil \tpin"] == nil, "伪造 ord key 被从库里清掉")
    ok(store.kv["sbb/evil \t假"] == nil, "伪造 sbb key 被从库里清掉")
    unload(fa2, ea2)
end

print("== 15. 文件有界：多次编辑 + 同步后，文件只留每个身份一条 ==")
do
    reset()
    _G.__wall, _G.__mono = 12000, 0
    use(MACHINES.A)
    local fa, ea = make_flow("t15a")
    for i = 1, 10 do
        _G.__mono = i * 10
        order.insert(fa, "e" .. i .. "|", "词" .. i, 1)
    end
    _G.__mono = 200
    for i = 1, 10 do
        order.insert(fa, "e" .. i .. "|k", "词" .. i, 1)   -- 每个身份再改一次
    end
    unload(fa, ea)
    sync_out(MACHINES.A)
    local before = #record_lines(MACHINES.A)
    eq(before, 10, "10 个身份、每个身份一条")
    -- 再同步几轮也不涨
    use(MACHINES.A)
    local fa2, ea2 = make_flow("t15a")
    unload(fa2, ea2)
    sync_out(MACHINES.A)
    eq(#record_lines(MACHINES.A), 10, "再 load/同步后仍是 10 条")
end

print("== 16. 状态一致时 load 不做无谓的 apply（性能） ==")
do
    reset()
    _G.__wall, _G.__mono = 13000, 0
    use(MACHINES.A)
    local fa, ea = make_flow("t16a")
    for i = 1, 50 do
        order.insert(fa, "p" .. i .. "|", "词" .. i, 1)
    end
    unload(fa, ea)
    sync_out(MACHINES.A)

    -- 重载：状态和记录一致 → 不该写库
    _G.__updates = 0
    use(MACHINES.A)
    local fa2, ea2 = make_flow("t16a")
    eq(_G.__updates, 0, "状态一致时 load 不写私有库")
    eq(#record_lines(MACHINES.A), 50, "50 条记录还在")
    unload(fa2, ea2)

    -- 远端改了其中一条 → 只应用变化
    _G.__wall, _G.__mono = 13001, 0
    use(MACHINES.B)
    local fb, eb = make_flow("t16b")
    order.insert(fb, "p1|x", "词1", 1)
    unload(fb, eb)
    sync_out(MACHINES.B)
    _G.__updates = 0
    use(MACHINES.A)
    local fa3, ea3 = make_flow("t16a")
    ok(_G.__updates > 0, "有远端更新时会写库")
    ok(_G.__updates < 50, "只应用变化的那几条（不是全量）")
    eq(order.get(fa3, "p1|x")[1], "词1", "远端更新生效")
    ok(order.get(fa3, "p1|") == nil, "旧位置被清掉")
    unload(fa3, ea3)
end

print()
print(string.format("共 %d 项检查，%d 项失败", checks, failures))
if failures > 0 then
    os.exit(1)
end
