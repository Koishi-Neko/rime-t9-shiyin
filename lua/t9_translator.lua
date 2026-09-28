-- t9_translator.lua — 纯数字输入 → 枚举首音节候选
--
-- 挂钩：translator: - lua_translator@*t9_translator
-- 行为：当一段输入是纯数字（如 94343）时，对每个「能作为首音节且剩余仍可切分」的
--       精确拼音（zhe / xie / …）产出一个候选，comment 里附完整切分预览。
--       候选 text 用 t9_core.candidate_text 决定（拼音 / 空 / 标记），
--       真正的“点选改写 input”由 t9_core 的 select_notifier 完成。

local core = require("t9_core")

local M = {}

function M.init(env)
    core.log("[translator.init] 首次初始化")
    if not env.__t9_notifier_installed then
        core.install_notifier(env)
        env.__t9_notifier_installed = true
    end
end

function M.func(input, seg, env)
    -- 只处理纯数字段；含撇号/字母的段交给 script_translator
    if not input:match("^[0-9]+$") then return end

    local ctx = env.engine.context
    local choices = core.prefix_choices(input)
    core.log(string.format("[translator] seg=%s..%s input=%s -> %d 个首音节选择",
        tostring(seg.start), tostring(seg._end or seg["end"]), input, #choices))

    for _, ch in ipairs(choices) do
        local full = ch.syl .. "'" .. ch.rest
        local previews = {}
        for k = 1, math.min(#ch.restsegs, 3) do
            previews[#previews + 1] = core.render(ch.restsegs[k])
        end
        local comment
        if ch.rest == "" then
            comment = string.format("%s | 完整：%s", ch.syl, ch.syl)
        else
            comment = string.format("%s'%s | 后续(%d)：%s",
                ch.syl, ch.rest, #ch.restsegs, table.concat(previews, " / "))
        end
        local text = core.candidate_text(ch.syl, ctx)
        local cand = Candidate("t9_syllable", seg.start, seg._end or seg["end"], text, comment)
        cand.quality = 100 + (10 - #ch.rest)  -- 剩余越短，越靠前
        core.log(string.format("[translator] yield text=%q comment=%q", text, comment))
        yield(cand)
    end
end

return M
