-- 键道 Flow 共享引擎 —— 形码数据与期望形码串
--
-- 期望形码串（两套方案各自的原版词库全量验证过）：
--   前 n-1 个字各取首键 + 最后一个字的完整形码。
-- 数据来自 <词库>.shape.txt（ZiDB 前 4 笔形，键位由 flow_engine/shape_keys
-- 或该文件本身决定，见 flow_env.lua）。

local flow_env = require("flow_env")

local M = {}

local function state(ctx)
    return flow_env.cache(ctx, "shapes",
                          { shapes = {}, expected_cache = {}, ready = false })
end

function M.init(env)
    local ctx = flow_env.ctx(env)
    local st = state(ctx)
    if st.ready then
        return true
    end
    local buf = flow_env.read(ctx, ".shape.txt")
    if not buf then
        log.warning("flow_shapes: 读不到 " ..
                    tostring(flow_env.base_name(ctx.dict)) .. ".shape.txt")
        return false
    end
    for line in buf:gmatch("[^\n]+") do
        if line:sub(1, 1) ~= "#" then
            local char, shape = line:match("^([^\t]+)\t([^\t]+)")
            if char then
                st.shapes[char] = shape
            end
        end
    end
    st.ready = true
    return true
end

-- 候选文本的期望形码串；任一字缺形码数据返回 nil
function M.expected(ctx, text)
    local st = state(ctx)
    local cached = st.expected_cache[text]
    if cached ~= nil then
        return cached or nil
    end
    local chars = {}
    for _, c in utf8.codes(text) do
        chars[#chars + 1] = utf8.char(c)
    end
    local n = #chars
    if n < 1 then
        st.expected_cache[text] = false
        return nil
    end
    local parts = {}
    for i = 1, n - 1 do
        local s = st.shapes[chars[i]]
        if not s or s == "" then
            st.expected_cache[text] = false
            return nil
        end
        parts[#parts + 1] = s:sub(1, 1)
    end
    local last = st.shapes[chars[n]]
    if not last or last == "" then
        st.expected_cache[text] = false
        return nil
    end
    parts[#parts + 1] = last
    local result = table.concat(parts)
    st.expected_cache[text] = result
    return result
end

-- shape 之后的下一个期望键；不匹配或没有则 nil
function M.next_key(ctx, text, shape)
    local exp = M.expected(ctx, text)
    if not exp or #shape >= #exp or exp:sub(1, #shape) ~= shape then
        return nil
    end
    return exp:sub(#shape + 1, #shape + 1)
end

function M.match(ctx, text, shape)
    if shape == "" then
        return true
    end
    local exp = M.expected(ctx, text)
    if not exp then
        return false
    end
    return exp:sub(1, #shape) == shape
end

-- 形码表里有没有这个字（纯笔码提示要判断）
function M.known(ctx, char)
    local st = state(ctx)
    return st.shapes[char] ~= nil
end

return M
