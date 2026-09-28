-- t9_processor.lua — 兜底方案：不用点选，用按键循环切换切分
--
-- 挂钩：processors: - lua_processor@*t9_processor   （放在 selector 之前）
-- 行为：输入纯数字时，按 Tab 或 F2 在「所有合法切分」之间循环，直接把 context.input
--       改写成带撇号的精确拼音（如 94343 → zhe'ge / zhe'he / xie'ge …）。
--       这条路径完全不依赖候选点选，作为 select_notifier 失效时的保底。

local core = require("t9_core")

local M = {}

function M.init(env)
    env.t9_cycle_index = 0
    env.t9_cycle_source = nil
end

function M.func(key, env)
    if key:release() then return 2 end
    local repr = key:repr()
    if repr ~= "Tab" and repr ~= "F2" then return 2 end

    local ctx = env.engine.context
    local input = ctx.input
    if input:match("^[0-9]+$") then
        env.t9_cycle_source = input        -- 原始数字串，循环期间保持不变
        env.t9_cycle_index = 0
        env.t9_cycle_last = nil
    elseif not (env.t9_cycle_source and ctx.input == (env.t9_cycle_last or env.t9_cycle_source)) then
        return 2                            -- 既不是数字，也不是本模块上一轮写出的串
    end

    local source = env.t9_cycle_source
    if not source then return 2 end
    local text, idx, total = core.cycle(env, source, 1)
    if not text then return 2 end

    ctx.input = text
    env.t9_cycle_last = text                -- 记住本轮写出的串，便于识别/继续循环
    core.log(string.format("[processor] %s 循环 %d/%d -> %s", input, idx, total, text))
    return 1
end

return M
