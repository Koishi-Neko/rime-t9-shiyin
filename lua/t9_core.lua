-- t9_core.lua — T9 数字串音节切分：共享逻辑
--
-- 职责：
--   1. 维护「合法音节 → 数字」前缀树（trie），提供 DFS 枚举所有合法切分
--   2. 提供「首音节可选集」：每个能作为首音节、且剩余部分仍可合法切分的 (数字前缀, 精确拼音)
--   3. 安装 select_notifier / commit_notifier，把「点选音节候选」变成「改写 context.input」
--
-- 本文件不直接挂到 schema，被 t9_translator.lua / t9_processor.lua 通过 require 使用。

local M = {}

-- ---------------------------------------------------------------------------
-- 调试日志：写文件，因为无头 harness 需要拿到 lua 内部的原始证据
-- ---------------------------------------------------------------------------
local LOG_PATH = os.getenv("T9_LOG") or "t9_debug.log"
local logf = nil
function M.log(msg)
    if logf == nil then
        logf = io.open(LOG_PATH, "a") or false
    end
    if logf then
        logf:write(os.date("%H:%M:%S ") .. msg .. "\n")
        logf:flush()
    end
end

-- ---------------------------------------------------------------------------
-- 1. 音节库存 与 字母→数字 映射
--    音节表来自 luna_pinyin.dict.yaml 的实际拼写（424 条，见 out/syllables.txt）
-- ---------------------------------------------------------------------------
local SYLLABLES = [[
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

-- 拼音串 → 数字串。非字母原样保留（本原型里输入只有字母/数字/撇号）
function M.to_digits(s)
    local out = {}
    for i = 1, #s do
        local c = s:sub(i, i)
        out[#out + 1] = DIGIT[c] or c
    end
    return table.concat(out)
end

-- ---------------------------------------------------------------------------
-- 2. 前缀树：节点 = { [digit] = child, syls = { 该节点结尾的拼音 } }
-- ---------------------------------------------------------------------------
local root = {}
local syllable_count = 0
for syl in SYLLABLES:gmatch("%S+") do
    local d = M.to_digits(syl)
    local node = root
    for i = 1, #d do
        local c = d:sub(i, i)
        node[c] = node[c] or {}
        node = node[c]
    end
    node.syls = node.syls or {}
    node.syls[#node.syls + 1] = syl
    syllable_count = syllable_count + 1
end
M.syllable_count = syllable_count

local MAX_RESULTS = 200  -- 上限，防止病态输入爆表

-- 枚举 digits 的全部合法全拼切分，返回 { {"zhe","ge"}, {"zhe","he"}, ... }
-- 空串返回 {{}}（表示「已切完」，一种空切分）
function M.enumerate(digits)
    local results = {}
    local path = {}
    local overflow = false
    local function dfs(pos)
        if #results >= MAX_RESULTS then overflow = true; return end
        if pos > #digits then
            local snapshot = {}
            for i = 1, #path do snapshot[i] = path[i] end
            results[#results + 1] = snapshot
            return
        end
        local node = root
        for i = pos, #digits do
            node = node[digits:sub(i, i)]
            if node == nil then break end
            if node.syls then
                for _, s in ipairs(node.syls) do
                    path[#path + 1] = s
                    dfs(i + 1)
                    path[#path] = nil
                end
            end
        end
    end
    dfs(1)
    return results, overflow
end

-- 首音节可选集：返回 { {len=n, syl="zhe", rest="43", restsegs={...}}, ... }
-- 只保留「剩余部分仍存在至少一种合法切分」的候选
function M.prefix_choices(digits)
    local out = {}
    local node = root
    for i = 1, #digits do
        node = node[digits:sub(i, i)]
        if node == nil then break end
        if node.syls then
            local rest = digits:sub(i + 1)
            local restsegs = M.enumerate(rest)
            if #restsegs > 0 then
                for _, s in ipairs(node.syls) do
                    out[#out + 1] = { len = i, syl = s, rest = rest, restsegs = restsegs }
                end
            end
        end
    end
    return out
end

-- 切分渲染成 "zhe'ge"
function M.render(seg)
    return table.concat(seg, "'")
end

-- ---------------------------------------------------------------------------
-- 3. 点选拦截：select_notifier 改写 context.input
-- ---------------------------------------------------------------------------
-- 候选 text 的三种模式（由 rime option 控制，便于一次编译内做 A/B）：
--   默认          text = 精确拼音（如 "zhe"）      —— 可读，但若改写失败会真的上屏
--   t9_empty_text text = ""                        —— 理想态：不泄漏任何文本
--   t9_marker_text text = "\1zhe\1"                —— 用标记兜底，commit_notifier 里识别
function M.candidate_text(syl, ctx)
    if ctx:get_option("t9_empty_text") then return "" end
    if ctx:get_option("t9_marker_text") then return "\1" .. syl .. "\1" end
    return syl
end

-- 从候选反推精确拼音（兼容三种 text 模式）
function M.candidate_syllable(cand)
    local t = cand.text or ""
    local m = t:match("^\1(%a+)\1$")
    if m then return m end
    if t:match("^%a+$") then return t end
    -- 空 text 模式：拼音藏在 comment 开头
    local c = cand.comment or ""
    return c:match("^(%a+)")
end

-- 引擎自己的 OnSelect 会先于我们的回调执行，并调用 composition().Forward()，
-- 于是 composition 末尾被塞进一个空 segment，back() 的 selected_candidate 变 nil。
-- 但被点中的那个 segment 仍留在 composition 里（带 selected_index / menu）。
-- 从后往前扫 composition，找最近一个「选中了 t9_syllable 候选」的非空 segment。
local function scan_selected_candidate(c)
    local comp = c.composition
    if comp == nil then return nil, "no composition" end
    local segs
    local ok, err = pcall(function()
        segs = comp:toSegmentation():get_segments()
    end)
    if not ok or segs == nil then return nil, "get_segments failed: " .. tostring(err) end
    local found = nil
    for i = #segs, 1, -1 do
        local seg = segs[i]
        local cand = seg:get_selected_candidate()
        M.log(string.format("  [seg %d/%d] status=%s start=%s _end=%s sel_idx=%s cand=%s",
            i, #segs, tostring(seg.status), tostring(seg.start), tostring(seg["_end"]),
            tostring(seg.selected_index), cand and tostring(cand.text) or "nil"))
        if found == nil and cand ~= nil and cand.type == "t9_syllable" then
            found = cand
            -- 调试：把该 segment 的完整菜单按序 dump 出来，核对 selected_index 与菜单顺序
            local menu = seg.menu
            if menu ~= nil then
                for k = 0, 20 do
                    local mc = menu:get_candidate_at(k)
                    if mc == nil then break end
                    M.log(string.format("    menu[%d] type=%s text=%q (selected_index=%s)",
                        k, tostring(mc.type), tostring(mc.text), tostring(seg.selected_index)))
                end
            end
        end
    end
    return found
end

function M.install_notifier(env)
    local ctx = env.engine.context

    env.t9_select_conn = ctx.select_notifier:connect(function(c)
        M.log("[select_notifier] input=" .. c.input .. " caret=" .. tostring(c.caret_pos))
        local cand = c:get_selected_candidate()
        if cand == nil then
            M.log("[select_notifier] back() 候选为 nil，改为扫描 composition 找被点中的 segment")
            cand = scan_selected_candidate(c)
        end
        if cand == nil then
            M.log("[select_notifier] 扫描后仍无 t9_syllable 候选 -> 放弃改写")
            return
        end
        M.log(string.format("[select_notifier] selected: type=%s text=%q comment=%q start=%s end=%s",
            tostring(cand.type), tostring(cand.text), tostring(cand.comment),
            tostring(cand.start), tostring(cand["end"])))
        local syl = M.candidate_syllable(cand)
        if not syl then
            M.log("[select_notifier] 无法从候选还原拼音，放弃")
            return
        end
        local digits = M.to_digits(syl)
        local input = c.input
        -- 候选的 seg 覆盖整段数字；只消费前 #digits 位，其余保留为后续 T9 数字
        local start = cand.start or 0          -- 0-based 或 1-based 视 librime 版本，做防御
        local head, consumed_pos
        if input:sub(start + 1, start + #digits) == digits then
            head = input:sub(1, start)         -- start 按 0-based（librime 惯用）
            consumed_pos = start + #digits
        elseif input:sub(start, start + #digits - 1) == digits then
            head = input:sub(1, start - 1)     -- 1-based 兜底
            consumed_pos = start + #digits - 1
        else
            -- 兜底：从头匹配第一个数字段
            head = ""
            local p = input:find("^'*%d+")
            consumed_pos = p and (p - 1 + #digits) or #digits
        end
        local rest = input:sub(consumed_pos + 1)
        -- 用撇号把「已确认音节」和「后续待切分数字」隔开。注意：这要求 schema 的
        -- speller 里配置 `delimiter: " '"`，否则撇号会被 script_translator 当作音节
        -- 中止点，`zhe'43` 只命中撇号前的「这」。踩坑记录见 REPORT.md。
        local newinput = head .. syl .. "'" .. rest
        M.log("[rewrite] " .. input .. "  --(" .. syl .. ")-->  " .. newinput)
        c.input = newinput
    end)

    env.t9_commit_conn = ctx.commit_notifier:connect(function(c)
        local ct = c:get_commit_text()
        M.log("[commit_notifier] commit_text=" .. tostring(ct))
    end)

    M.log("[install] 音节树载入 " .. syllable_count .. " 条音节；notifier 已连接")
end

-- ---------------------------------------------------------------------------
-- 4. 兜底：不用点选，用按键循环切分（processor 用）
-- ---------------------------------------------------------------------------
function M.cycle(env, original, step)
    local segs, _ = M.enumerate(original)
    if #segs == 0 then return nil end
    env.t9_cycle_index = ((env.t9_cycle_index or 0) + step - 1) % #segs + 1
    return M.render(segs[env.t9_cycle_index]), env.t9_cycle_index, #segs
end

return M
