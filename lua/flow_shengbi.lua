-- 键道 Flow 共享引擎 —— 声笔简码（默认表 + 用户覆盖）
--
-- 默认表来自 <词库>.shengbi.dict.yaml：码 = 一声母键 + 1~N 个笔形键。
-- 输入是「一声母键 + 笔形键」（sb / sbb / sbbb…）时，flow_filter 跳过
-- <词库>.shape.txt 的期望形码筛选（形码键本来也不会进输入串），
-- 直接用整串码来这张表里查：命中就是这些词。输入 sb 码时还会把同前缀
-- 的 sbb 也带上（hint = 还差的笔形键，假装自动补全），见 flow_filter。
--
-- 用户覆盖：`` ` ` 声笔调整模式里按 - / = 把当前词组设成 sb / sbb，存在
-- flow_order 的 sbb/<码>（一个码一条 key，不动别的）；正常输入该码按 =
-- 删掉覆盖、回默认表。见 README「声笔简码」。
--
-- 每个方案（schema_id）各自一份状态：见 flow_env.lua。

local flow_env = require("flow_env")
local order = require("flow_order")
local codes = require("flow_codes")
local shapes = require("flow_shapes")
local create = require("flow_create")

local M = {}

-- 默认表状态只挂 flow_env 的 cache（teardown / 换词库时会被整体清掉重建）
local function state(ctx)
    return flow_env.cache(ctx, "shengbi", { codes = {}, ready = false })
end

function M.init(ctx)
    local st = state(ctx)
    if st.ready then
        return true
    end
    local buf = flow_env.read(ctx, ".shengbi.dict.yaml")
    if not buf then
        st.ready = true          -- 没配这张表就当空表
        return false
    end
    -- 跳过 YAML 头（到 `...` 为止）；行 = 词 [tab] 码 [tab] 权重(可省)
    local in_header = true
    for line in buf:gmatch("[^\n]+") do
        if in_header then
            if line == "..." then
                in_header = false
            end
        elseif line:sub(1, 1) ~= "#" then
            local text, code, w = line:match("^([^\t]+)\t([^\t]+)\t([%d%.]+)$")
            if not text then
                text, code = line:match("^([^\t]+)\t([^\t]+)$")
            end
            if text and code and code ~= "" then
                local list = st.codes[code]
                if not list then
                    list = {}
                    st.codes[code] = list
                end
                list[#list + 1] = { text = text, w = tonumber(w) or 0 }
            end
        end
    end
    st.ready = true
    return true
end

-- 该码的候选：用户覆盖优先（nil = 没这张码 / 覆盖里显式取消），否则默认表。
-- 返回保持表内顺序的 { text = ..., w = ... } 列表。
function M.get(ctx, code)
    if not state(ctx).ready then
        M.init(ctx)
    end
    local override = order.get_shengbi(ctx, code)
    if override ~= nil then
        if override == "" then
            return nil
        end
        return { { text = override, w = 0 } }
    end
    return state(ctx).codes[code]
end

-- 正常模式按 =：当前码（一声母键 + 笔形键）有用户覆盖时删掉、回默认表。
-- 返回 true 表示这个 `=` 被当作「还原」处理（不再去 lower_or_extend）。
function M.revert(flow, ctx)
    local input = ctx.input or ""
    local shape = ctx:get_property("flow_shape") or ""
    if #input ~= 1 or shape == "" then
        return false
    end
    local sound = flow_env.sound_keys(flow) or ""
    if not sound:find(input, 1, true) then
        return false
    end
    local code = input .. shape
    if order.get_shengbi(flow, code) == nil then
        return false
    end
    order.clear_shengbi(flow, code)
    ctx:refresh_non_confirmed_composition()
    return true
end

local function utf8_chars(text)
    local chars = {}
    for _, c in utf8.codes(text) do
        chars[#chars + 1] = utf8.char(c)
    end
    return chars
end

-- 词组的声笔简码：首字声母 + 末字前 keys 笔（keys = 1 -> sb，2 -> sbb）。
-- 和默认表同一套规则；取不到（没码 / 没形码数据 / 笔画不够）返回 nil。
function M.code_for(flow, phrase, keys)
    local chars = utf8_chars(phrase)
    if #chars == 0 then
        return nil
    end
    local init = codes.initial(flow, chars[1])
    local shape = shapes.expected(flow, chars[#chars])
    if not init or not shape or #shape < keys then
        return nil
    end
    return init .. shape:sub(1, keys)
end

-- 声笔调整模式里按 - / =：把当前词组设为 sb / sbb，直接入库（flow_order），
-- 去掉 ` 前缀并把输入换成这个码（音码进 input、笔形进 flow_shape），
-- 和造词入库后的状态一致。
function M.assign(flow, ctx, keys)
    local seg = ctx.composition and ctx.composition:back()
    if seg and (seg._end - seg.start) > 0 then
        return                   -- 还有没确认的段（正在打/还在选）：吞掉，不猜
    end
    local phrase = create.strip_markers(ctx:get_commit_text())
    local code = phrase ~= "" and M.code_for(flow, phrase, keys) or nil
    if not code then
        if phrase ~= "" and log and log.warning then
            log.warning("flow_shengbi: 「" .. phrase .. "」算不出声笔简码，放弃")
        end
        create.exit(flow, ctx)
        ctx:clear()
        ctx:set_property("flow_shape", "")
        return
    end
    order.remove_shengbi_word(flow, phrase)   -- 同一个词换码，不留旧码
    order.set_shengbi(flow, code, phrase)
    create.exit(flow, ctx)
    ctx:clear()
    ctx:set_property("flow_shape", code:sub(2))
    ctx:push_input(code:sub(1, 1))
end

return M
