-- 键道 Flow 共享引擎 —— 次简表（默认值 + 用户覆盖/学习）
--
-- 默认值 = 原版 buchong「二重」段的**单键**条目。
-- buchong 里多键的「二重」（叭br 氏uy 嘁qy…）不在这里——那些是原版
-- 词库层面的第 2 位，不是次简；笔码（纯笔形开头）也不给次简，
-- 因为笔码候选里没有别的字可选（Tab 也不处理）。
-- 用户覆盖/学习写在 flow_order 的 ~secondary 键里，优先于默认；覆盖值
-- 为空字符串表示取消该码的默认次简。
--
-- 两套方案的默认表只差一个键（27C 是 u，27 是 e）：表里两行都留着，
-- 查的时候用本方案的声母键过滤，谁用的键位谁生效。
--
-- 「码」= 用户实际敲的键（音码 + 形码），例如 z / zto。
-- Tab 的行为见 flow_shape：当前码有次简就上屏次简，没有则上屏当前候选
-- 并把它学成该码首键的次简（如 kffy → 可以 → k 的次简）。

local flow_env = require("flow_env")
local order = require("flow_order")

local M = {}

M.defaults = {
    b = "吧", d = "打", f = "发", h = "嘿", j = "及", l = "啦", m = "嘛",
    n = "哪", q = "期", t = "挺", w = "玩", x = "嗯", y = "重", z = "咱",
    u = "实", e = "实",
}

local function state(flow)
    return flow_env.cache(flow, "secondary", { enabled = true })
end

-- 读配置（由 flow_shape / flow_filter 的 init 调用）；总开关
-- flow_secondary: false 时整块关掉（Tab 处理、次简候选、学习），
-- 已经存下的 ~secondary 数据保留，重新打开就恢复。
function M.init(flow)
    local st = state(flow)
    if flow.config then
        local ok, v = pcall(function()
            return flow.config:get_bool("flow_secondary")
        end)
        if ok and v ~= nil then
            st.enabled = v
        end
    end
    return true
end

function M.enabled(flow)
    return state(flow).enabled
end

-- 该码的次简；nil = 没有（功能关掉 / 用户显式取消 / 表里没有 / 键位不属于本方案）
-- 默认表按**完整码**查（和上游一致：例 z 命中，zto 不命中；用户覆盖同理），
-- 只是多一步「首键必须属于本方案的声母键」——两套方案的默认表合并成了一张，
-- 不过滤的话 27C 会命中 27 的 e 行。
function M.get(flow, code)
    if not state(flow).enabled then
        return nil
    end
    local override = order.get_secondary(flow, code)
    if override ~= nil then
        if override == "" then
            return nil
        end
        return override
    end
    local d = M.defaults[code]
    if d == nil then
        return nil
    end
    local key = code:sub(1, 1)
    if not flow_env.sound_keys(flow):find(key, 1, true) then
        return nil
    end
    return d
end

-- 记一条（Tab 学习 / 用户覆盖；功能关掉时不写）
function M.set(flow, code, text)
    if not state(flow).enabled then
        return
    end
    order.set_secondary(flow, code, text)
end

return M
