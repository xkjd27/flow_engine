-- 键道 Flow 共享引擎 —— 形码处理器 + 顶功 + 手动调序
--
-- 负责：
--   * 形码键      -> 输入串只有笔形键时进入输入串，由纯形码表（<词库>.shape）
--                    匹配；否则存进 flow_shape 属性，由 flow_filter 筛候选
--   * ` 造词模式、`` 声笔调整模式（见 flow_create / flow_shengbi）
--   * Tab 次简、动作键（promote / demote 一个键多种场合；键位在 schema 的
--     flow_engine/bindings 里配）
--   * 翻页键（prev_page / next_page，到头按 flow_engine/page_edge 处理）
--   * BackSpace 删形码 / 造词模式下按字删
--   * 顶功与四码自动上屏
--
-- 声母键里的标点（`;`）连按两个给候选 —— 见 flow_filter（标点值取 schema
-- 的 punctuator 段，全角 / 半角各一份）。
--
-- 声母键 / 笔形键来自 schema 的 flow_engine/*（见 flow_env.lua）。

local flow_env = require("flow_env")
local order = require("flow_order")
local shapes = require("flow_shapes")
local codes = require("flow_codes")
local create = require("flow_create")
local shengbi = require("flow_shengbi")
local secondary = require("flow_secondary")

local PROP = "flow_shape"
local XK_BACKSPACE = 0xff08
local XK_TAB = 0xff09
local XK_RETURN = 0xff0d
local XK_ESCAPE = 0xff1b

local function state(flow)
    return flow_env.cache(flow, "shape_processor", {})
end

-- 本方案的笔形键集合（char -> true），按方案缓存
local function shape_key_set(flow)
    local st = state(flow)
    if not st.keys then
        local set = {}
        for ch in flow_env.shape_keys(flow):gmatch(".") do
            set[ch] = true
        end
        st.keys = set
    end
    return st.keys
end

local function get_shape(ctx)
    return ctx:get_property(PROP) or ""
end

local function set_shape(ctx, s)
    ctx:set_property(PROP, s)
    ctx:refresh_non_confirmed_composition()
end

local function commit_current(ctx)
    if ctx:is_composing() then
        if ctx:get_selected_candidate() then
            ctx:commit()
        else
            ctx:clear()
        end
    end
end

-- 翻页键（schema: flow_engine/bindings/prev_page / next_page）转发给 selector
-- （它认 Page_Up / Page_Down，翻页标记等行为跟原来的 key_binder 绑定一致），
-- 翻动了就吞掉按键；没翻动（已经在第一页 / 最后一页）按 flow_engine/page_edge：
--   ignore  吞掉
--   topup   顶屏：当前内容上屏，然后这个按键接着往下走（`[` 顺带出「候选）
--   pass    不顶，直接交给后面的处理器
-- 标点候选（punct）不归翻页键管：那种时候连按是换标点候选，交给 punctuator。
-- 返回 true = 这个按键已处理完（调用方 return 1），false = 继续往下走。
local function page_event(flow, name)
    local st = state(flow)
    st.page_events = st.page_events or {}
    local ev = st.page_events[name]
    if not ev then
        ev = KeyEvent(name)
        st.page_events[name] = ev
    end
    return ev
end

local function selected_index(ctx)
    local seg = ctx.composition and ctx.composition:back()
    return seg and seg.selected_index or nil
end

-- 当前是不是标点候选（punct）：是的话翻页键要让路（连按换候选）
local function punct_segment(ctx)
    local seg = ctx.composition and ctx.composition:back()
    local cand = seg and seg:get_selected_candidate()
    return cand and cand.type == "punct"
end

local function page_key(flow, env, ctx, code, is_create)
    local b = flow_env.bindings(flow)
    local name
    if b.prev_page ~= 0 and code == b.prev_page then
        name = "Page_Up"
    elseif b.next_page ~= 0 and code == b.next_page then
        name = "Page_Down"
    else
        return false
    end
    if not ctx:is_composing() then
        return false        -- 没组合：`[` 还是出「
    end
    if punct_segment(ctx) then
        return false        -- 标点候选：`[` `]` 连按是换候选
    end
    -- 有候选才有页可翻（没候选时 Page_Down 会漏给编辑器/应用）
    if ctx:has_menu() then
        local before = selected_index(ctx)
        env.engine:process_key(page_event(flow, name))
        if selected_index(ctx) ~= before then
            return true     -- 翻动了
        end
    end
    -- 到头了。造词模式里顶屏会把造词标记一起上屏，按 ignore 处理
    local edge = is_create and "ignore" or b.edge
    if edge == "topup" then
        if ctx:has_menu() and ctx:get_selected_candidate() then
            ctx:commit()
            ctx:set_property(PROP, "")
            -- 顶屏之后按键继续：`[` 接着出「候选，想打标点随时可选
            return false
        end
        return true
    end
    return edge ~= "pass"
end

-- 把 text 放到 input|shape 的首位；目标位若已被其他候选占据，
-- 被顶掉的候选沿它自己的形码串顺延到下一级，递归直到有空位；
-- 已到完整形码仍无空位则丢弃该 pin（回归自然排序）。
-- 递归深度由候选自己的期望形码长度兜底（每层形码 +1，不会死循环）。
-- syl 非空时表示这是一次音码削减，完整音节会随 pin 保存。
local function place(flow, text, input, shape, syl)
    local function put(t, s, sy)
        local key = input .. "|" .. s
        local list = order.get(flow, key)
        local occupant = list and list[1]
        if occupant == t then
            return
        end
        local occ_syl
        if occupant then
            occ_syl = order.get_syllable(flow, key, occupant)
            order.remove(flow, key, occupant)
        end
        order.insert(flow, key, t, 1, sy)
        if occupant then
            local exp = shapes.expected(flow, occupant)
            if exp and #s < #exp and exp:sub(1, #s) == s then
                put(occupant, exp:sub(1, #s + 1), occ_syl)
            end
        end
    end
    put(text, shape, syl)
end

-- 把一段的文本换成 text。Rime 没有「删字」的 API，用单候选菜单替换；
-- 已确认的段之后不会被重翻译，替换能保持住。
local function set_segment_text(ctx, seg, text)
    local repl = Candidate("flow_order", seg.start, seg._end, text, "")
    repl.preedit = text
    -- Translation 的生成函数要用插件的全局 yield() 产出候选（不能 return）
    local trans = Translation(function()
        yield(repl)
    end)
    local menu = Menu()
    menu:add_translation(trans)
    menu:prepare(1)
    seg.menu = menu
    seg.selected_index = 0
    seg.status = "kSelected"
    ctx.input = ctx.input   -- 触发重画
end

-- `-` 降档（上调）：把候选从当前级别移走，pin 到更短一级；
--   补全来的词（pin 在别的级别）先 pin 到本级，pin 在更短级别时从
--   它自己的级别再上一级；单字全码（声韵）在最短级别继续削到 1 键简码；
--   已在最短级别（1 键简码）则 pin 在当前位置。
local function promote(flow, ctx)
    local cand = ctx:get_selected_candidate()
    if not cand or not cand.text or cand.text == "" then
        return
    end
    local shape = get_shape(ctx)
    local input = ctx.input
    local level = order.pin_level(flow, input, cand.text)
    if flow_env.is_shape_input(flow, input) then
        -- 纯笔码：码即完整形码，没有更短的级别；把候选提到本级首位
        -- （不走 place，避免被顶掉的候选顺延到笔码输入打不出的更长 key）
        order.remove_pin(flow, cand.text)
        order.insert(flow, input .. "|", cand.text, 1)
    elseif shape ~= "" then
        local target
        if level == nil or level == shape then
            -- 普通候选（没 pin）或 pin 就在本级：本级再短一档
            target = shape:sub(1, -2)
        elseif #level < #shape then
            -- 补全来的词（pin 在更短的级别）：从它自己的级别再上一级
            target = level:sub(1, -2)
        else
            -- 补全来的词（pin 在更长的级别）：先 pin 到本级
            target = shape
        end
        order.remove_pin(flow, cand.text)
        place(flow, cand.text, input, target)
        ctx:set_property(PROP, target)
    elseif utf8.len(cand.text) == 1 and #input == 2 and
            (level == nil or level == "") then
        -- 声韵 -> 1 键简码；完整音节记进 order，供 = 还原
        order.remove_pin(flow, cand.text)
        local short = input:sub(1, 1)
        place(flow, cand.text, short, "", input)
        ctx.input = short
    else
        order.remove_pin(flow, cand.text)
        place(flow, cand.text, input, "")
    end
    ctx:refresh_non_confirmed_composition()
end

-- `=` 升档/下调：1 键级别优先用记录的音节还原到声韵（否则反查）；
--   其它情况补下一笔形码并 pin 到更长一级，从词自己的 pin 级别延长
--   （补全来的词 pin 在别的级别，别从当前级别延长把它提上来）；
--   已到完整形码则在它那一级的 key 内下移一位（下调）。
local function lower_or_extend(flow, ctx)
    local cand = ctx:get_selected_candidate()
    if not cand or not cand.text or cand.text == "" then
        return
    end
    local shape = get_shape(ctx)
    local input = ctx.input
    local key = input .. "|" .. shape
    local level = order.pin_level(flow, input, cand.text)
    if flow_env.is_shape_input(flow, input) then
        -- 纯笔码：码即完整形码，已是最长级别，在本 key 内下移一位
        order.move_down(flow, key, cand.text)
        ctx:refresh_non_confirmed_composition()
        return
    end
    if shape == "" and #input == 1 and
            (level == nil or level == "") then
        local syl = order.get_syllable(flow, key, cand.text)
        if not syl then
            local rest = codes.next_keys(flow, cand.text, input)
            if rest and #rest == 1 then
                syl = input .. rest
            end
        end
        if syl then
            order.remove_pin(flow, cand.text)
            order.insert(flow, syl .. "|", cand.text, 1)
            ctx.input = syl
            ctx:refresh_non_confirmed_composition()
            return
        end
    end
    local base = level or shape
    local next = shapes.next_key(flow, cand.text, base)
    if not next then
        if cand.type == "flow_order" then
            -- 补出来的自造词：到完整形码后别把它移出 pin（否则词会从
            -- 所有级别整个消失），在本级末位待着就行
            order.move_down_keep(flow, input .. "|" .. base, cand.text)
        else
            order.move_down(flow, input .. "|" .. base, cand.text)
        end
        ctx:refresh_non_confirmed_composition()
        return
    end
    -- 补码升档：本级首位让给下一个候选（`uyhs=` 后重打 `uyhs` 由「事后」接替）
    local seg = ctx.composition and ctx.composition:back()
    if seg and seg.selected_index == 0 then
        local second = seg:get_candidate_at(1)
        if second and second.text and second.text ~= "" then
            order.remove_pin(flow, second.text)
            order.insert(flow, key, second.text, 1)
        end
    end
    order.remove_pin(flow, cand.text)
    local target = base .. next
    order.insert(flow, input .. "|" .. target, cand.text, 1)
    ctx:set_property(PROP, target)
    ctx:refresh_non_confirmed_composition()
end

local function processor(key_event, env)
    local flow = flow_env.of(env)
    if not flow then                     -- init 没成功：不处理按键
        return 2
    end
    if key_event:release() or key_event:ctrl() or key_event:alt() then
        return 2
    end
    local ctx = env.engine.context
    local code = key_event.keycode
    create.tick(flow, ctx)
    local is_create = create.active(flow, ctx)

    -- `：从空输入进入造词模式（标记进输入串）；造词中再按一个 ` 且还没打
    -- 内容就切到声笔调整模式（`` 前缀）；已打内容则视为非法内容：已输内容
    -- 连同这个 ` 直接上屏（交给标点/编辑器）
    local mark = create.is_trigger(code)
    if mark then
        if is_create then
            if create.mode(flow) == "create" and ctx.input == mark then
                create.enter_shengbi(flow, ctx)
                return 1
            end
            create.exit(flow, ctx)
            return 2
        end
        if not ctx:is_composing() then
            create.enter(flow, ctx, mark)
            return 1
        end
        return 2
    end

    -- Esc：退出造词模式（输入交给 editor 清掉）
    if is_create and code == XK_ESCAPE then
        create.exit(flow, ctx)
        return 2
    end

    -- Tab：次简。当前码有次简 → 上屏次简；否则上屏当前候选，并把它
    -- 学成该码首键的次简（如 `kffy` 的可以 → `k` 的次简）
    if code == XK_TAB and not is_create and secondary.enabled(flow) then
        if ctx:is_composing() and ctx:has_menu() then
            local raw = ctx.input .. get_shape(ctx)
            -- 首码是笔码（纯笔码输入）时不给次简，Tab 直接吞掉：
            -- 笔码候选里没有别的字可选
            if not raw:match("^[" .. flow_env.sound_keys(flow) .. "]") then
                return 1
            end
            local want = secondary.get(flow, raw)
            local cand = ctx:get_selected_candidate()
            if not want and raw ~= "" and cand and cand.text and cand.text ~= "" then
                want = cand.text
                secondary.set(flow, raw:sub(1, 1), want)
            end
            if want and want ~= "" then
                -- engine:commit_text 不会触发 commit_notifier，手动清状态
                ctx:set_property(PROP, "")
                ctx:clear()
                env.engine:commit_text(want)
            end
            return 1
        end
        return 2
    end

    -- BackSpace：优先删形码；造词模式下已确认的文本按字删（像上屏后
    -- 在应用里按退格），删空的那一段再整段删（连同它的输入）
    if code == XK_BACKSPACE then
        local s = get_shape(ctx)
        if s ~= "" then
            set_shape(ctx, s:sub(1, -2))
            return 1
        end
        if is_create then
            if #ctx.input <= 1 then
                create.exit(flow, ctx)
                return 2
            end
            local comp = ctx.composition
            local seg = comp:back()
            if seg and (seg._end - seg.start) == 0 then
                comp:pop_back()   -- 尾部空段
                seg = comp:back()
            end
            if seg and (seg.status == "kSelected" or
                    seg.status == "kConfirmed") then
                local cand = seg:get_selected_candidate()
                local text = (cand and cand.text) or ""
                local n = utf8.len(text)
                if n and n > 1 then
                    -- 去掉最后一个字，保留这段的输入和位置
                    set_segment_text(ctx, seg,
                                     text:sub(1, utf8.offset(text, n) - 1))
                    return 1
                end
                -- 只剩一个字（或没候选）：整段连输入一起删
                ctx.input = ctx.input:sub(1, seg.start)
                return 1
            end
            -- 还没确认的输入：逐键删
            ctx.input = ctx.input:sub(1, -2)
            return 1
        end
        return 2
    end

    -- 翻页键：能翻就翻，到头按 flow_engine/page_edge（见 page_key）
    if page_key(flow, env, ctx, code, is_create) then
        return 1
    end

    -- 造词模式：空格/数字用于分词选择；
    -- 还没打码（只有 `）或无候选时，空格视为非法内容，直接上屏退出
    if is_create then
        if code == 0x20 then
            local code_part = create.strip_markers(ctx.input)
            -- 最近造词选中后空格：确认进 context（不上屏、不退出造词），
            -- 状态变成 `` `简直了 ``，之后可以 = 删除或 - 重新按全码入库
            if code_part == "" and ctx:has_menu() and
                    create.recent_selected(flow, ctx) then
                return 2
            end
            if code_part == "" or not ctx:has_menu() then
                -- 数字选过候选后段会关闭、尾巴变成空段（无菜单）：
                -- 空格没有要确认的东西，留在造词模式就好；
                -- 否则会把 `` `哈级 `` 这种带标记的原文直接上屏
                local seg = ctx.composition and ctx.composition:back()
                if code_part ~= "" and seg and
                        (seg._end - seg.start) == 0 then
                    return 1
                end
                create.exit(flow, ctx)
                return 2  -- Editor::Confirm → ConfirmCurrentSelection || Commit
            end
            -- 分词：确认当前段（_auto_commit 已关，不上屏）。先确认再清形码，
            -- 顺序反了会用清掉形码后的候选（可能是别的词）；形码带进下一段
            -- 会让造词模式用上一段的形码筛下一段的读音（simp 下尤明显）
            ctx:confirm_current_selection()
            ctx:set_property(PROP, "")
            return 1
        end
        if code >= 0x30 and code <= 0x39 and not ctx:has_menu() then
            return 1  -- 防止落到 express_editor 的 DirectCommit
        end
    end

    -- 动作键（schema: flow_engine/bindings/*，只有 promote / demote 两个键）：
    --   正常模式   调序上调 / 降档延长
    --   造词模式   入库 / 删除
    --   声笔调整   设为 sb / 设为 sbb
    local b = flow_env.bindings(flow)
    local act
    if b.promote ~= 0 and code == b.promote then
        act = "promote"
    elseif b.demote ~= 0 and code == b.demote then
        act = "demote"
    end
    if act then
        if is_create then
            if act == "promote" then
                if create.mode(flow) == "shengbi" then
                    shengbi.assign(flow, ctx, 1)
                else
                    create.store(flow, ctx)
                end
            else
                if create.mode(flow) == "shengbi" then
                    shengbi.assign(flow, ctx, 2)
                else
                    create.delete(flow, ctx)
                end
            end
            return 1
        end
        -- 正常模式的 `=`：当前码是声笔简码且有用户覆盖时，先删覆盖、回默认表
        if act == "demote" and shengbi.revert(flow, ctx) then
            return 1
        end
        if ctx:has_menu() and ctx:get_selected_candidate() then
            if act == "promote" then
                promote(flow, ctx)
            else
                lower_or_extend(flow, ctx)
            end
            return 1
        end
        -- 组合中但没有候选（形码已超过词的全码、码还没打完等）：吞掉按键，
        -- 否则 express_editor 会把原文连按键一起上屏（hjn= 这种）
        if ctx:is_composing() then
            return 1
        end
        return 2
    end

    -- 回车：原样上屏输入（含形码），不走 express_editor 的原始输入
    -- （后者只提交 ctx.input，会丢掉 flow_shape 里的形码）
    if code == XK_RETURN then
        if ctx:is_composing() then
            local text = ctx.input .. get_shape(ctx)
            if text ~= "" then
                if is_create then
                    create.exit(flow, ctx)
                end
                -- engine:commit_text 不会触发 commit_notifier，手动清形码状态
                ctx:set_property(PROP, "")
                ctx:clear()
                env.engine:commit_text(text)
                return 1
            end
        end
        return 2
    end

    if code < 0x20 or code >= 0x7f then
        return 2
    end
    local key = string.char(code)

    -- 形码键
    if shape_key_set(flow)[key] then
        if ctx:is_composing() then
            -- 纯笔码输入（还没有音码）：形码进入输入串，交给纯形码表匹配
            if ctx.input == "" or flow_env.is_shape_input(flow, ctx.input) then
                return 2
            end
            set_shape(ctx, get_shape(ctx) .. key)
            return 1
        end
        return 2
    end

    -- 音码键
    if key:match("^[a-z;]$") then
        if is_create then
            -- 造词模式：不自动上屏，但顶功照常「前进」——当前段音码满
            -- 4 键或已有形码时，把这一段确认掉（composition 保留），
            -- 下一个键开始新的一段：`jm;yl 会边打边前进成「`简直l」
            local seg = ctx.composition and ctx.composition:back()
            local seg_len = seg and (seg._end - seg.start) or 0
            local s = get_shape(ctx)
            if (s ~= "" or seg_len >= 4) and ctx:is_composing() and
                    ctx:get_selected_candidate() then
                ctx:confirm_current_selection()
                ctx:set_property(PROP, "")
            end
            return 2
        end
        local s = get_shape(ctx)
        if s ~= "" then
            -- 顶码（形码）后自动上屏
            commit_current(ctx)
            ctx:set_property(PROP, "")
        elseif #ctx.input >= 4 and ctx:is_composing() and
                ctx:get_selected_candidate() then
            -- 四码自动上屏：已有 4 个音码键且当前有候选，再按音码键先上屏；
            -- 若无候选（如 5 键节奏码的前 4 键不合法），则让按键继续延长输入
            ctx:commit()
        end
    end

    return 2
end

local function init(env)
    local flow = flow_env.attach(env)
    if not flow then
        return            -- 方案没配 flow_engine/*：引擎不启用
    end
    order.init(flow)
    shapes.init(flow)
    codes.init(flow)
    secondary.init(flow)
    env.flow_shape_conn = env.engine.context.commit_notifier:connect(
        function(ctx)
            ctx:set_property(PROP, "")
            create.reset(flow, ctx)
        end)
end

-- 与 init 里的 order.init 配对（引用计数）：
-- 少了这里 order.userdb 的 LOCK 直到进程退出都不会释放
-- （schema 切换 / 引擎销毁时就会一直占着）。先关库，再放掉方案引用。
local function fini(env)
    local flow = flow_env.of(env)
    if not flow then
        return
    end
    if env.flow_shape_conn then
        env.flow_shape_conn:disconnect()
        env.flow_shape_conn = nil
    end
    order.close(flow)
    flow_env.release(env)
end

return { func = processor, init = init, fini = fini }
