-- t9_syllable_cycle.lua — 兜底：Tab / F2 循环切换音节切分（九宫拾音）
--
-- 挂钩（schema/engine/processors，放在首位）：
--     - lua_processor@*t9_syllable_cycle
--
-- 行为：输入末尾还有待切分数字时，按 Tab（或 F2）在它的所有合法读法之间循环，直接把
--       context.input 改写成带撇号的精确拼音；已确认的前缀原样保留，所以连续按 Tab 可以
--       一段一段往下切：
--           94343 → xi'e'ge → xi'e'he → … → zhe'ge
--           zhe'43 → zhe'ge → zhe'he → …        （只循环尾部 43 的读法）
--       这条路径不依赖候选点选，作为 select_notifier 失效（宿主不派发 select 事件）时的保底。
--
-- 只在两种情况消费按键，其余一律返回 kNoop(2) 放行：
--   1. 当前输入末尾是待切分数字，且满足与 translator 相同的门槛
--      （首段要 ≥2 种切分；续段只要尾部数字 ≥2 个读法）
--   2. 当前输入就是本模块上一轮写出来的串（继续循环）
-- 所以普通打字、以及 default.yaml 里 `Tab → Shift+Right` 的光标移动，只有在这两种情况下
-- 才会被接管。

local core = require("t9_syllable_core")

local M = {}

function M.init(env)
    env.t9_syllable_cycle_index = 0
    env.t9_syllable_cycle_source = nil
    env.t9_syllable_cycle_head = nil
    env.t9_syllable_cycle_last = nil
end

function M.func(key, env)
    if key:release() then return 2 end
    local repr = key:repr()
    if repr ~= "Tab" and repr ~= "F2" then return 2 end

    local ctx = env.engine.context
    local input = ctx.input
    local prefix, tail = core.split_tail(input)
    if tail ~= nil and not ctx:get_option("t9_syllable_off") then
        -- 门槛与 t9_syllable.lua 保持一致：首段（整串都是数字）要 ≥2 种切分；
        -- 续段（前面已有确认音节）只要尾部数字有 ≥2 个读法就接着切。
        if prefix == "" then
            if #core.splits(tail, 2) < 2 then return 2 end
        else
            if #core.readings(tail, 2) < 2 then return 2 end
        end
        env.t9_syllable_cycle_head = prefix    -- 已确认前缀（含撇号），循环期间不变
        env.t9_syllable_cycle_source = tail    -- 待切分数字，循环期间不变
        env.t9_syllable_cycle_index = 0
        env.t9_syllable_cycle_last = nil
    elseif env.t9_syllable_cycle_source == nil or input ~= env.t9_syllable_cycle_last then
        return 2                               -- 既不是待切分数字，也不是本模块上一轮写出的串
    end

    local reading = core.cycle(env, env.t9_syllable_cycle_source, 1)
    if not reading or reading == "" then return 2 end

    local text = (env.t9_syllable_cycle_head or "") .. reading
    ctx.input = text
    env.t9_syllable_cycle_last = text          -- 记住本轮写出的串，便于识别/继续循环
    core.log(string.format("[processor] %s 循环 %d/%d -> %s",
        input, env.t9_syllable_cycle_index, #core.readings(env.t9_syllable_cycle_source),
        text))
    return 1
end

return M
