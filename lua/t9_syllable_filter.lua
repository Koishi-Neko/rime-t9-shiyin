-- t9_syllable_filter.lua — 把音节候选的 end 缩到「首音节末尾」（九宫拾音）
--
-- 挂钩（schema/engine/filters 末尾，放在各 simplifier 之后）：
--     - lua_filter@*t9_syllable_filter
--
-- 为什么需要这一道 filter（两件互相冲突的事，只能分开做）：
--   1. 候选排序由 librime 的 Candidate::compare 决定：同一 start 下 **end 大者优先**
--      （src/rime/candidate.cc：先比 start 小的在前，再比 end 大的在前，最后比 quality）。
--      所以音节候选必须按**整段数字**产出，才能排在 script_translator 的词典候选前面。
--   2. 但引擎的 OnSelect（src/rime/engine.cc）在「被选候选的 end == 输入长度」时会
--      把该段标记为已确认并**自动提交整段输入**，我们的 select_notifier 就来不及改写。
--      Segment::Close() 只在 cand.end < seg.end 时把段截断成 partial 选择（不提交）。
--   做法：translator 按整段产出拿到排序，本 filter 在菜单成型后把音节候选的 end
--   缩到「首音节末尾」→ 点选时引擎按 partial 处理 → 不自动提交 → select_notifier
--   把 94343 改写成 zhe'43。词典候选完全不动，仍然一按即上屏。
--
-- 调试开关：t9_syllable_no_partial 打开时本 filter 原样放行（用于验证
-- t9_syllable_core 里的「整段提交补救路径」）。

local core = require("t9_syllable_core")

local M = {}

function M.func(input, env)
    local no_partial = env.engine.context:get_option("t9_syllable_no_partial")
    for cand in input:iter() do
        local shrunk = nil
        if not no_partial and cand.type == "t9_syllable" then
            local syl = core.candidate_syllable(cand)
            local digits = syl and #core.to_digits(syl) or 0
            if digits > 0 then
                shrunk = Candidate(cand.type, cand.start, cand.start + digits,
                    cand.text, cand.comment)
                shrunk.quality = cand.quality or 100
                core.log(string.format("[filter] %s: 候选 end %s -> %d（partial 选择）",
                    syl, tostring(cand["end"]), cand.start + digits))
            end
        end
        yield(shrunk or cand)
    end
end

return M
