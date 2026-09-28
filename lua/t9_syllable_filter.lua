-- t9_syllable_filter.lua — 把音节候选的 end 缩到「本次要消费的数字」末尾（九宫拾音）
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
--   缩到「本次消费的数字末尾」→ 点选时引擎按 partial 处理 → 不自动提交 →
--   select_notifier 把 94343 改写成 zhe'43、把 zhe'43 改写成 zhe'ge。
--
--   另外：当本次消费的数字一直顶到**输入末尾**时（末音节，如 43 → ge），缩到末尾
--   仍然等于输入长度，引擎照样会自动提交。这时再缩一位，让它成为 partial 选择——
--   改写只用到「音节本身 + 候选起点」，多余的那一位数字会被改写后的 input 覆盖掉，
--   于是点任何一步音节都**不会产生任何提交**（含末音节）。
--
-- 调试开关：t9_syllable_no_partial 打开时本 filter 原样放行（用于验证
-- t9_syllable_core 里的「整段提交补救路径」）。

local core = require("t9_syllable_core")

local M = {}

function M.func(input, env)
    local ctx = env.engine.context
    local no_partial = ctx:get_option("t9_syllable_no_partial")
    local ctx_input = ctx.input or ""
    local input_len = #ctx_input
    local prefix, tail = core.split_tail(ctx_input)
    for cand in input:iter() do
        local shrunk = nil
        if not no_partial and cand.type == "t9_syllable" and tail ~= nil then
            local syl = core.candidate_syllable(cand)
            local digits = syl and #core.to_digits(syl) or 0
            if digits > 0 and #tail >= digits then
                -- 本次消费到的位置：已确认前缀 + 这个音节的数字位数
                local span_end = #prefix + digits
                if span_end >= input_len and span_end - 1 > #prefix then
                    -- 末音节（刚好顶到输入末尾）：再缩一位，避免
                    -- 「end == 输入长度」让引擎在点选时自动提交
                    span_end = span_end - 1
                end
                shrunk = Candidate(cand.type, 0, span_end, cand.text, cand.comment)
                shrunk.quality = cand.quality or 100
                core.log(string.format("[filter] %s: 候选 end %s -> %d（partial 选择）",
                    syl, tostring(cand["end"]), span_end))
            end
        end
        yield(shrunk or cand)
    end
end

return M
