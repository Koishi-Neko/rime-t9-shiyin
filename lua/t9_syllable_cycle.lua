-- t9_syllable_cycle.lua — 兜底：Tab / F2 循环切换音节切分（九宫拾音）
--
-- 挂钩（schema/engine/processors，放在首位）：
--     - lua_processor@*t9_syllable_cycle
--
-- 行为：纯数字输入且存在多种切分时，按 Tab（或 F2）在所有合法切分之间循环，直接把
--       context.input 改写成带撇号的精确拼音：
--           94343 → xi'e'ge → … → zhe'ge → …
--       这条路径不依赖候选点选，作为 select_notifier 失效（宿主不派发 select 事件）时的保底。
--
-- 只在两种情况消费按键，其余一律返回 kNoop(2) 放行：
--   1. 当前输入是纯数字且存在多种切分（与 translator 的门槛一致）
--   2. 当前输入就是本模块上一轮写出的串（继续循环）
-- 所以普通打字、以及 default.yaml 里 `Tab → Shift+Right` 的光标移动，只有在
-- 「数字串确实存在多种切分」这一种情况下才会被接管。

local core = require("t9_syllable_core")

local M = {}

function M.init(env)
    env.t9_syllable_cycle_index = 0
    env.t9_syllable_cycle_source = nil
    env.t9_syllable_cycle_last = nil
end

function M.func(key, env)
    if key:release() then return 2 end
    local repr = key:repr()
    if repr ~= "Tab" and repr ~= "F2" then return 2 end

    local ctx = env.engine.context
    local input = ctx.input
    if input:match("^[0-9]+$") then
        if #core.splits(input, 2) < 2 then return 2 end
        env.t9_syllable_cycle_source = input   -- 原始数字串，循环期间保持不变
        env.t9_syllable_cycle_index = 0
        env.t9_syllable_cycle_last = nil
    elseif not (env.t9_syllable_cycle_source
        and input == (env.t9_syllable_cycle_last or env.t9_syllable_cycle_source)) then
        return 2                               -- 既不是数字，也不是本模块上一轮写出的串
    end

    local source = env.t9_syllable_cycle_source
    if not source then return 2 end

    local text, idx, total = core.cycle(env, source, 1)
    if not text or text == "" then return 2 end

    ctx.input = text
    env.t9_syllable_cycle_last = text          -- 记住本轮写出的串，便于识别/继续循环
    core.log(string.format("[processor] %s 循环 %d/%d -> %s", input, idx, total, text))
    return 1
end

return M
