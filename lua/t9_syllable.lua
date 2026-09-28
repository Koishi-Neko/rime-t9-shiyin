-- t9_syllable.lua — 纯数字输入 → 音节候选（九宫拾音 · 雾凇拼音九宫格 t9 方案）
--
-- 挂钩（schema/engine/translators，放在 script_translator 之前）：
--     - lua_translator@*t9_syllable
--
-- 行为：某段输入是纯数字（如 94343）**且存在多种合法音节切分**时，为每个可选「首音节」
--       （zhe / xie / zhei …）产出一个候选。候选 text 留空（不泄漏任何文本），
--       精确拼音与后续切分预览放在 comment 里（括号里是「后续还有几种数字切分」）：
--           text=''  comment="zhe'43 | 后续(1)：ge"
--       点选后的改写（94343 → zhe'43）由 t9_syllable_core 的 select_notifier 完成。
--
-- 切分门槛：只有 ≥2 种切分、且首音节可选 ≥2 个时才出音节候选；单一切分直接把菜单
--           让给词典候选（普通九宫格输入完全不受影响）。
--
-- 放置位置：本文件与 t9_syllable_core.lua / t9_syllable_cycle.lua 一起放进手机包的
--           lua/ 目录（与 rime-ice-t9-phone 的 t9_preedit.lua 等同级）。

local core = require("t9_syllable_core")

local M = {}

function M.init(env)
    if not env.__t9_syllable_notifier then
        core.install_notifier(env)
        env.__t9_syllable_notifier = true
    end
end

function M.func(input, seg, env)
    -- 只处理纯数字段；含撇号/字母的段交给 script_translator
    if not input:match("^[0-9]+$") then return end

    -- 门槛：单一切分时不出音节候选，直接出词典候选
    if #core.splits(input, 2) < 2 then
        core.log("[translator] " .. input .. " 只有单一切分 -> 不出音节候选")
        return
    end
    local choices = core.prefix_choices(input)
    if #choices < 2 then
        core.log("[translator] " .. input .. " 首音节可选不足 2 个 -> 不出音节候选")
        return
    end

    local ctx = env.engine.context
    core.log(string.format("[translator] seg=%s..%s input=%s -> %d 个首音节选择",
        tostring(seg.start), tostring(seg._end or seg["end"]), input, #choices))

    for _, ch in ipairs(choices) do
        local comment
        if ch.rest == "" then
            comment = string.format("%s | 完整：%s", ch.syl, ch.syl)
        else
            comment = string.format("%s'%s | 后续(%d)：%s",
                ch.syl, ch.rest, ch.tail_total, table.concat(ch.tails, " / "))
        end
        local text = core.candidate_text(ch.syl, ctx)
        -- 候选**按整段数字**产出（end = 段 end）：librime 的 Candidate::compare 对同一
        -- start 是「end 大者优先」，只有覆盖整段才能排在词典候选前面。
        -- 真正点选时把 end 缩到「首音节末尾」是 t9_syllable_filter.lua 干的活：
        -- 那时引擎会按 partial 选择处理，不会自动提交整段输入，select_notifier 才能改写。
        local cand = Candidate("t9_syllable", seg.start, seg._end or seg["end"], text, comment)
        -- 统一给 100：高于 custom_phrase 的 99 与 script_translator 的初始权重，
        -- 保证音节候选排在所有词典候选前面（translators 里的位置是另一重保险）。
        cand.quality = 100
        core.log(string.format("[translator] yield code=%s syl=%s text=%q comment=%q",
            ch.code, ch.syl, text, comment))
        yield(cand)
    end
end

return M
