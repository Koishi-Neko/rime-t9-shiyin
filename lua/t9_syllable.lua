-- t9_syllable.lua — 数字段 → 音节候选（九宫拾音 · 雾凇拼音九宫格 t9 方案）
--
-- 挂钩（schema/engine/translators，放在 script_translator 之前）：
--     - lua_translator@*t9_syllable
--
-- 行为：只要**输入末尾还有一段待切分的数字**（最后一位音节之前可以已经有确认好的音节），
--       就为每个可选「首音节」（zhe / xie / zhei …）产出一个候选。候选 text 就是音节本身
--       （真机候选条直接显示可点选的音节按钮），comment 放这个候选定下来的写法
--       （短，且会被 rime-ice 手机端当作第一行 preedit 显示）：
--           text='zhe'  comment="zhe'43"
--       点选后的改写（94343 → zhe'43 → zhe'ge）由 t9_syllable_core 的 select_notifier 完成。
--       所以点完一个音节之后，剩余数字会再来一轮音节候选 —— 连续逐字选音节。
--
-- 切分门槛：
--   * 首段（整段就是数字）：要 ≥2 种切分，单一切分（98 / 94 这种）不出音节候选，
--     把菜单让给词典候选，普通九宫格输入完全不受影响。
--   * 续段（前面已有确认音节）：只要尾部数字有 ≥2 个首音节可选就继续出（例如 43 → ge / he），
--     因为用户已经明确在用「逐字选音节」这条路了。
--
-- 放置位置：本文件与 t9_syllable_core.lua / t9_syllable_cycle.lua / t9_syllable_filter.lua
--           一起放进手机包的 lua/ 目录（与 rime-ice-t9-phone 的 t9_preedit.lua 等同级）。

local core = require("t9_syllable_core")

local M = {}

function M.init(env)
    if not env.__t9_syllable_notifier then
        core.install_notifier(env)
        env.__t9_syllable_notifier = true
    end
end

function M.func(input, seg, env)
    -- 只处理「末尾还有待切分数字」的段；含撇号但尾部无数字的段交给 script_translator
    local prefix, tail = core.split_tail(input)
    if tail == nil then return end
    -- 调试开关：整体停用音节候选（用于在真机/桌面上做 A/B 对照）
    if env.engine.context:get_option("t9_syllable_off") then return end

    -- 首段 / 续段：门槛不同（见文件头说明）
    local continuation = prefix ~= "" or seg.start > 0
    if not continuation and #core.splits(tail, 2) < 2 then
        core.log("[translator] " .. tail .. " 只有单一切分 -> 不出音节候选")
        return
    end
    local choices = core.prefix_choices(tail)
    if #choices < 2 then
        core.log("[translator] " .. tail .. " 首音节可选不足 2 个 -> 不出音节候选")
        return
    end

    local ctx = env.engine.context
    local seg_end = seg._end or seg["end"]
    core.log(string.format("[translator] seg=%s..%s input=%s（%s）tail=%s -> %d 个首音节选择",
        tostring(seg.start), tostring(seg_end), input, continuation and "续段" or "首段",
        tail, #choices))

    for _, ch in ipairs(choices) do
        -- comment = 这个候选定下来的写法（zhe'43 / ge）。
        -- rime-ice 的 t9 方案里「第一行 preedit 是拿候选 comment 渲染的」
        -- （见 t9.schema.yaml 的 translator/comment_format 注释），所以这里放完整读法最有用，
        -- 而且足够短 —— 不再拼「后续(3)：e'ge / di'e / die」那种长文案。
        local comment = ch.rest == "" and ch.syl or (ch.syl .. "'" .. ch.rest)
        local text = core.candidate_text(ch.syl, ctx)
        -- 候选**按整段输入**产出（start=段起点、end=段终点）：librime 的 Candidate::compare
        -- 是先比 start 小的在前、再比 end 大的在前。续段（zhe'43）里词典候选的 start 是 0，
        -- 所以音节候选的 start 也必须是 0，才能靠 quality=100 排在词典候选前面。
        -- 点选时真正生效的跨度由 t9_syllable_filter.lua 缩到「本次消费的数字末尾」，
        -- 那时引擎按 partial 选择处理，不会自动提交，select_notifier 才能改写 input。
        local cand = Candidate("t9_syllable", seg.start, seg_end, text, comment)
        -- 统一给 100：高于 custom_phrase 的 99 与 script_translator 的初始权重，
        -- 保证音节候选排在所有词典候选前面（translators 里的位置是另一重保险）。
        cand.quality = 100
        core.log(string.format("[translator] yield code=%s syl=%s text=%q comment=%q",
            ch.code, ch.syl, text, comment))
        yield(cand)
    end
end

return M
