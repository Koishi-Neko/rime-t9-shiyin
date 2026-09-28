-- t9_syllable_core.lua — T9 数字串音节切分：共享逻辑（雾凇拼音九宫格 t9 方案）
--
-- 职责：
--   1. 载入「合法音节 → 数字串」前缀树，DFS 枚举数字串的全部合法切分
--   2. 给出「首音节可选集」：数字前缀 + 精确拼音（t9_syllable 候选用）
--   3. 安装 select_notifier：点选音节候选后把 context.input 从 94343 改写成 zhe'43
--
-- 数据来源（重要，别在这里再抄一份数字码表）：
--   * 合法音节的**数字码表**运行时读取手机包自带的
--     lua/t9_default_abbreviation_segmentor.lua 里的 FULL_PINYIN_CODES
--     （t9 主 prism 实际接受的数字拼写集合）。读不到时退化为「由 LETTERS 推导」。
--   * LETTERS 只负责把数字码还原成精确拼音（94 → xi / yi / zi），供候选、注释与改写使用。
--
-- 本文件不直接挂 schema，由 t9_syllable.lua（translator）与
-- t9_syllable_cycle.lua（processor，Tab 兜底）通过 require 使用。
--
-- 移植说明与 Trime 侧待验证点见 schema/PORTING.md。

local M = {}

-- ---------------------------------------------------------------------------
-- 0. 调试日志：写文件（无头 harness 需要 lua 内部证据）；未设 T9_LOG 时完全关闭
-- ---------------------------------------------------------------------------
local LOG_PATH = os.getenv("T9_LOG") or os.getenv("T9_SYLLABLE_LOG")
local logf = nil
function M.log(msg)
    if not LOG_PATH then return end
    if logf == nil then
        local ok, f = pcall(io.open, LOG_PATH, "a")
        logf = (ok and f) or false
    end
    if logf then
        logf:write(os.date("%H:%M:%S ") .. msg .. "\n")
        logf:flush()
    end
end

-- ---------------------------------------------------------------------------
-- 1. 字母表：数字码 → 精确拼音 的还原依据（424 条，雾凇/luna_pinyin 的拼写习惯）
-- ---------------------------------------------------------------------------
local LETTERS = [[
a ai an ang ao ba bai ban bang bao bei ben beng bi bian biang biao bie bin bing bo bu
ca cai can cang cao ce cei cen ceng cha chai chan chang chao che chen cheng chi chong
chou chu chua chuai chuan chuang chui chun chuo ci cong cou cu cuan cui cun cuo da dai
dan dang dao de dei den deng di dia dian diao die din ding diu dong dou du duan dui dun
duo e eh ei en eng er fa fan fang fei fen feng fiao fo fong fou fu ga gai gan gang gao
ge gei gen geng gong gou gu gua guai guan guang gui gun guo ha hai han hang hao he hei
hen heng hong hou hu hua huai huan huang hui hun huo ji jia jian jiang jiao jie jin jing
jiong jiu ju juan jue jun ka kai kan kang kao ke kei ken keng kong kou ku kua kuai kuan
kuang kui kun kuo la lai lan lang lao le lei leng li lia lian liang liao lie lin ling liu
lo long lou lu luan lun luo lv lvan lve ma mai man mang mao me mei men meng mi mian miao
mie min ming miu mo mou mu na nai nan nang nao ne nei nen neng ni nia nian niang niao nie
nin ning niu nong nou nu nuan nun nuo nv nve o ou pa pai pan pang pao pei pen peng pi pia
pian piao pie pin ping po pou pu qi qia qian qiang qiao qie qin qing qiong qiu qu quan que
qun ran rang rao re ren reng ri rong rou ru rua ruan rui run ruo sa sai san sang sao se sei
sen seng sha shai shan shang shao she shei shen sheng shi shou shu shua shuai shuan shuang
shui shun shuo si song sou su suan sui sun suo ta tai tan tang tao te tei teng ti tian tiao
tie ting tong tou tu tuan tui tun tuo wa wai wan wang wei wen weng wo wong wu xi xia xian
xiang xiao xie xin xing xiong xiu xu xuan xue xun ya yai yan yang yao ye yi yin ying yo
yong you yu yuan yue yun za zai zan zang zao ze zei zen zeng zha zhai zhan zhang zhao zhe
zhei zhen zheng zhi zhong zhou zhu zhua zhuai zhuan zhuang zhui zhun zhuo zi zong zou zu
zuan zui zun zuo
]]

local DIGIT = {
    a = 2, b = 2, c = 2, d = 3, e = 3, f = 3, g = 4, h = 4, i = 4,
    j = 5, k = 5, l = 5, m = 6, n = 6, o = 6, p = 7, q = 7, r = 7, s = 7,
    t = 8, u = 8, v = 8, w = 9, x = 9, y = 9, z = 9,
}

-- 拼音串 → 数字串；非字母原样保留
function M.to_digits(s)
    local out = {}
    for i = 1, #s do
        local c = s:sub(i, i)
        out[#out + 1] = DIGIT[c] or c
    end
    return table.concat(out)
end

-- ---------------------------------------------------------------------------
-- 2. 前缀树：节点 = { [digit] = child, terminal = true, letters = { 精确拼音 } }
--    树的「哪些数字串是合法音节」这一信息来自手机包，不在本文件里重复维护。
-- ---------------------------------------------------------------------------
local SEGMENTOR_MODULE = "t9_default_abbreviation_segmentor"
local SEGMENTOR_FILE = SEGMENTOR_MODULE .. ".lua"
local CODE_BLOCK_PATTERN = "FULL_PINYIN_CODES%s*=%s*%[%[(.-)%]%]"

local root = {}
local code_set = {}

-- 依次尝试：本文件所在目录 → 其上一级 lua/ → package.path → 相对路径。
-- （桌面小狼毫与 Android Trime 的用户目录布局/工作目录不同，逐个试最稳。）
local function load_segmentor_source()
    local tried = {}
    local function try(path)
        if not path then return nil end
        tried[#tried + 1] = path
        local ok, f = pcall(io.open, path, "r")
        if not ok or not f then return nil end
        local text = f:read("*a")
        f:close()
        if text and text:find("FULL_PINYIN_CODES", 1, true) then return text, path end
        return nil
    end

    local info = debug and debug.getinfo and debug.getinfo(1, "S")
    local src = (info and info.source or ""):gsub("^@", "")
    local dir = src:match("^(.*)[/\\][^/\\]*$")
    if dir then
        local text, path = try(dir .. "/" .. SEGMENTOR_FILE)
        if text then return text, path end
        local parent = dir:gsub("[/\\]lua$", "")
        text, path = try(parent .. "/lua/" .. SEGMENTOR_FILE)
        if text then return text, path end
    end
    if package and package.searchpath then
        local ok, path = pcall(package.searchpath, SEGMENTOR_MODULE, package.path or "")
        if ok and type(path) == "string" then
            local text, got = try(path)
            if text then return text, got end
        end
    end
    local text, path = try("lua/" .. SEGMENTOR_FILE)
    if text then return text, path end
    text, path = try(SEGMENTOR_FILE)
    if text then return text, path end
    return nil, nil, tried
end

local function add_code(code)
    if code_set[code] then return false end
    code_set[code] = true
    local node = root
    for i = 1, #code do
        local d = code:sub(i, i)
        node[d] = node[d] or {}
        node = node[d]
    end
    node.terminal = true
    return true
end

local function node_of(code)
    local node = root
    for i = 1, #code do
        node = node[code:sub(i, i)]
        if node == nil then return nil end
    end
    return node
end

-- 字母表 → 数字码 → 拼音列表
local letters_by_code = {}
local letter_count = 0
for syl in LETTERS:gmatch("%S+") do
    local code = M.to_digits(syl)
    letters_by_code[code] = letters_by_code[code] or {}
    local list = letters_by_code[code]
    list[#list + 1] = syl
    letter_count = letter_count + 1
end

local code_source, code_total, code_missing = "LETTERS(回退)", 0, 0
do
    local text, path = load_segmentor_source()
    local block = text and text:match(CODE_BLOCK_PATTERN)
    if block then
        code_source = path
        for code in block:gmatch("%d+") do
            if add_code(code) then code_total = code_total + 1 end
        end
    end
    if code_total == 0 then
        code_source = "LETTERS(回退：未读到包内码表)"
        for code in pairs(letters_by_code) do
            if add_code(code) then code_total = code_total + 1 end
        end
    end
    -- 防御：包内码表若被改动/删除，本文件里的字母仍必须可用
    for code in pairs(letters_by_code) do
        if add_code(code) then code_missing = code_missing + 1 end
    end
    for code, list in pairs(letters_by_code) do
        local node = node_of(code)
        if node then node.letters = list end
    end
end

-- 供 harness / 日志核对
M.letter_count = letter_count
M.code_count = code_total
M.code_source = code_source
M.code_missing = code_missing
M.codes = code_set

-- ---------------------------------------------------------------------------
-- 3. 切分枚举
-- ---------------------------------------------------------------------------
local MAX_SPLITS = 200    -- 单次枚举上限，防病态输入爆表
local MAX_STEPS = 20000   -- DFS 步数预算

-- digits 的全部合法切分（每个切分 = { 数字码, 数字码, ... }），最多返回 limit 个
function M.splits(digits, limit)
    limit = limit or MAX_SPLITS
    local out = {}
    if digits == "" then return out end
    local steps = MAX_STEPS
    local path = {}
    local function dfs(pos)
        if #out >= limit or steps <= 0 then return end
        steps = steps - 1
        if pos > #digits then
            local snapshot = {}
            for i = 1, #path do snapshot[i] = path[i] end
            out[#out + 1] = snapshot
            return
        end
        local node = root
        for i = pos, #digits do
            node = node[digits:sub(i, i)]
            if node == nil then break end
            if node.terminal then
                path[#path + 1] = digits:sub(pos, i)
                dfs(i + 1)
                path[#path] = nil
            end
        end
    end
    dfs(1)
    return out
end

-- 切分 → 可读写法：能还原成精确拼音的用拼音，还原不了的（包内模糊派生码）保留数字码
function M.render_split(split)
    local out = {}
    for i = 1, #split do
        local code = split[i]
        local node = node_of(code)
        out[i] = (node and node.letters and node.letters[1]) or code
    end
    return table.concat(out, "'")
end

-- 首音节可选集：{ { code, syl, rest, tails={写法,...}, tail_total }, ... }
-- 只保留「剩余部分仍有合法切分」的数字前缀（最后一位音节除外，此时 rest == ""）
function M.prefix_choices(digits)
    local out = {}
    local node = root
    for i = 1, #digits do
        node = node[digits:sub(i, i)]
        if node == nil then break end
        if node.terminal and node.letters then
            local rest = digits:sub(i + 1)
            local tails = rest == "" and {} or M.splits(rest, MAX_SPLITS)
            if rest == "" or #tails > 0 then
                local preview = {}
                for k = 1, math.min(#tails, 3) do
                    preview[k] = M.render_split(tails[k])
                end
                for _, syl in ipairs(node.letters) do
                    out[#out + 1] = {
                        code = digits:sub(1, i),
                        len = i,             -- 首音节占用的数字位数
                        syl = syl,
                        rest = rest,
                        tails = preview,     -- 最多 3 种后续切分写法（comment 预览用）
                        tail_total = #tails,
                    }
                end
            end
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- 4. 候选文本：默认留空（零泄漏）
--    默认          text = ""     —— 预编辑/提交都不含候选文本，标签信息全在 comment
--    t9_syllable_text text = 精确拼音 —— 候选条更醒目，但宿主若直接提交整段输入会把拼音当文本上屏
--    （移植前的 A/B 结论见 docs/syllable-prototype-report.md §4.3：空 text 是唯一零泄漏的模式）
-- ---------------------------------------------------------------------------
function M.candidate_text(syl, ctx)
    if ctx:get_option("t9_syllable_text") then return syl end
    return ""
end

-- 从候选反推精确拼音（空 text 模式看 comment 开头；文本模式直接看 text）
function M.candidate_syllable(cand)
    local t = cand.text or ""
    if t:match("^%a+$") then return t end
    return (cand.comment or ""):match("^(%a+)")
end

-- 引擎自己的 OnSelect 会先于我们的回调执行：被点/被确认的那个 segment 会先被
-- Segment::Close() 按 partial 截断，composition 末尾又补上「剩余输入」的新 segment。
-- 因此**不能**用 context:get_selected_candidate()（那是末尾那段的“高亮”候选，
-- 不是用户选中的东西）。从后往前扫 composition，只认「用户真的选过」的段
-- （status = selected/confirmed），再取其中 type 为 t9_syllable 的候选。
local function user_selected(seg)
    local st = seg.status
    if type(st) == "number" then
        return st >= 2   -- kVoid=0, kGuess=1, kSelected=2, kConfirmed=3
    end
    st = tostring(st)
    return st == "selected" or st == "confirmed"
        or st == "kSelected" or st == "kConfirmed"
end

local function scan_selected_candidate(c)
    local comp = c.composition
    if comp == nil then return nil end
    local segs
    local ok, err = pcall(function()
        segs = comp:toSegmentation():get_segments()
    end)
    if not ok or segs == nil then
        M.log("[scan] get_segments 失败：" .. tostring(err))
        return nil
    end
    local found = nil
    for i = #segs, 1, -1 do
        local seg = segs[i]
        local cand = seg:get_selected_candidate()
        M.log(string.format("  [seg %d/%d] status=%s start=%s _end=%s sel_idx=%s cand=%s/%q",
            i, #segs, tostring(seg.status), tostring(seg.start), tostring(seg["_end"]),
            tostring(seg.selected_index), cand and tostring(cand.type) or "nil",
            cand and tostring(cand.text) or ""))
        if found == nil and cand ~= nil and user_selected(seg) then
            if cand.type == "t9_syllable" then
                found = cand
            else
                M.log("  [scan] 该段用户选中的是普通候选，停止上溯")
                break
            end
        end
    end
    return found
end

function M.install_notifier(env)
    local ctx = env.engine.context

    env.t9_syllable_select_conn = ctx.select_notifier:connect(function(c)
        local input = c.input
        local cand = scan_selected_candidate(c)
        if cand ~= nil then
            local syl = M.candidate_syllable(cand)
            if syl then
                env.t9_syllable_pending = nil
                M.rewrite(c, input, cand.start or 0, syl)
                return
            end
            M.log("[select_notifier] 无法从候选还原拼音，放弃改写")
            return
        end
        -- 补救路径：引擎已抢先把整段输入提交掉了（composition 被清空），
        -- 用 commit_notifier 暂存的信息继续改写。
        local pending = env.t9_syllable_pending
        if pending ~= nil and input == "" then
            env.t9_syllable_pending = nil
            M.log("[select_notifier] 走补救路径（引擎已整段提交）")
            M.rewrite(c, pending.input, pending.start, pending.syl)
            return
        end
        M.log("[select_notifier] 不是音节候选，交给引擎默认行为")
    end)

    -- 补救路径：若音节候选恰好覆盖整段输入（end == 输入长度），引擎的 OnSelect 会在
    -- 我们的回调之前就 Commit 整段（commit_notifier 先于 select_notifier 里的后续处理，
    -- 此时 composition 已被清空）。这里趁 commit_notifier 还能看到选中候选与原始 input，
    -- 先暂存下来，让 select_notifier 补救改写 —— 这样即使 partial 机制失效（例如
    -- t9_syllable_no_partial 调试开关打开），点选音节也不会丢输入。
    env.t9_syllable_commit_conn = ctx.commit_notifier:connect(function(c)
        local cand = c:get_selected_candidate()
        if cand and cand.type == "t9_syllable" then
            local syl = M.candidate_syllable(cand)
            if syl then
                M.log("[commit_notifier] 音节候选被整段提交，暂存输入以便补救：" ..
                    tostring(c.input) .. " / " .. syl)
                env.t9_syllable_pending = { input = c.input, start = cand.start or 0, syl = syl }
            end
        end
    end)

    M.log(string.format("[install] 音节树：%d 个数字码（%s），%d 个可还原拼音；补入 %d 个",
        code_total, code_source, letter_count, code_missing))
end

-- 把「已确认音节」写回 context.input：94343 --(zhe)--> zhe'43
function M.rewrite(c, input, start, syl)
    local digits = M.to_digits(syl)
    local head, consumed
    if input:sub(start + 1, start + #digits) == digits then
        head = input:sub(1, start)              -- start 按 0-based
        consumed = start + #digits
    elseif input:sub(start, start + #digits - 1) == digits then
        head = input:sub(1, start - 1)          -- 1-based 兜底
        consumed = start + #digits - 1
    else
        head = ""
        local p = input:find("^'*%d+")
        consumed = p and (p - 1 + #digits) or #digits
    end
    local rest = input:sub(consumed + 1)
    -- 用撇号隔开「已确认音节」与「后续待切分数字」。依赖 schema 的
    -- speller/delimiter 含单引号，否则撇号会被当成音节中止点（见 PORTING.md）。
    local newinput = rest == "" and (head .. syl) or (head .. syl .. "'" .. rest)
    M.log("[rewrite] " .. input .. "  --(" .. syl .. ")-->  " .. newinput)
    c.input = newinput
end

-- 数字串的「可读切分」全集：每个数字码展开成它的每一个精确拼音（94 → xi/yi/zi），
-- 还原不了的（包内模糊派生码）保留数字串本身。Tab 循环用它，
-- 保证 zhe'ge / xie'he 这类「同一数字码的另一种读法」也能循环到。
function M.readings(digits, limit)
    limit = limit or MAX_SPLITS
    local out, seen, path = {}, {}, {}
    if digits == "" then return out end
    local steps = MAX_STEPS
    local function dfs(pos)
        if #out >= limit or steps <= 0 then return end
        steps = steps - 1
        if pos > #digits then
            local text = table.concat(path, "'")
            if not seen[text] then
                seen[text] = true
                out[#out + 1] = text
            end
            return
        end
        local node = root
        for i = pos, #digits do
            node = node[digits:sub(i, i)]
            if node == nil then break end
            if node.terminal then
                local letters = node.letters
                if letters then
                    for _, syl in ipairs(letters) do
                        path[#path + 1] = syl
                        dfs(i + 1)
                        path[#path] = nil
                    end
                else
                    path[#path + 1] = digits:sub(pos, i)
                    dfs(i + 1)
                    path[#path] = nil
                end
            end
        end
    end
    dfs(1)
    return out
end

-- ---------------------------------------------------------------------------
-- 5. 兜底：不依赖点选，按键循环切分（t9_syllable_cycle.lua 用）
-- ---------------------------------------------------------------------------
function M.cycle(env, digits, step)
    step = step or 1
    if digits == nil or digits == "" then return nil end
    local readings = M.readings(digits)
    if #readings == 0 then return nil end
    env.t9_syllable_cycle_index = ((env.t9_syllable_cycle_index or 0) + step - 1) % #readings + 1
    return readings[env.t9_syllable_cycle_index], env.t9_syllable_cycle_index, #readings
end

return M
