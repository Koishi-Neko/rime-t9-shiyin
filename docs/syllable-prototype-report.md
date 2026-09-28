# T9 音节切分原型 —— 技术验证报告

> 目标：验证「T9 数字串 → 枚举所有合法拼音切分 → 用户点选音节 → 预编辑区改写为精确拼音」
> 这条链路在 **librime 引擎层**是否可行，为 Android 同文输入法（Trime）九宫格做前置验证。
>
> 本报告所有结论均由 `harness.py` 在 Windows 桌面用真实 `rime.dll`（librime + librime-lua）
> **无头实跑**得到，附真实输入/输出转录。全文没有「理论上应该行」的结论。

---

## 0. 结论速览

| 机制 | 内容 | 结论 |
|---|---|---|
| **M1** | 纯数字串枚举所有合法全拼切分（Lua DFS） | ✅ 通过 |
| **M2** | 把每个可选「首音节」产出为候选（`lua_translator`） | ✅ 通过 |
| **M3** | 点选音节候选 → 不改上屏、改写 `context.input` 为精确拼音 | ✅ 通过（三种候选 text 模式全部通过） |
| **M4** | 改写后 `zhe'43` 混合接力：字母按精确拼音 + 数字继续 T9 | ✅ 通过 |
| 兜底 | `lua_processor` 按键（Tab/F2）循环切分，不依赖点选 | ✅ 通过 |

**推荐最终方案**：`fluid_editor` + 候选 text 留空（empty 模式）+ `filters` 去掉 `uniquifier`
+ 点选后经 `scan_selected_candidate` 扫描 composition 识别被点中音节 + 改写为 `拼音'剩余数字`。
该方案在引擎层 **零文本泄漏**（预编辑/提交都不带任何候选文本）。

---

## 1. 验证环境与方法

- 引擎：小狼毫 `C:\Program Files\Rime\weasel-0.17.4\rime.dll`（librime 1.13.1，带 librime-lua）
- shared data：`C:\Program Files\Rime\weasel-0.17.4\data`
- 用户目录：**沙箱** `out/user/`（全程不碰 `%APPDATA%\Rime`，不运行 WeaselDeployer）
- harness：`harness.py`，用 `ctypes` 直接调 `rime_get_api()`，进程内建会话、逐键/`set_input` 驱动
- 复现：

```bash
python harness.py all --mode empty    # 部署 + 跑全部场景，写 transcripts/run_empty.txt
python harness.py all --mode text
python harness.py all --mode marker
python harness.py deploy              # 只重建沙箱并编译方案
python harness.py run  --mode empty   # 只跑场景（假定已 deploy）
```

> `all` 会先用 deployer 编译方案，再**另起一个进程**跑场景。deployer 与 engine 必须分进程，
> 否则会互相干扰（踩坑记录见 §5）。

---

## 2. M1 —— 切分枚举

Lua 侧用「音节库前缀树 + DFS」枚举，Python 侧用一份**独立实现**的参考枚举做交叉对照，
两者结果一致。音节库 424 条（取自 `luna_pinyin` 实际拼写，见 `out/syllables.txt`）。

`transcripts/run_empty.txt` 转录：

```
input=94    -> 3 segmentations: xi; yi; zi
input=9434  -> 10 segmentations: xi'di; xi'eh; xi'ei; yi'di; yi'eh; yi'ei; zi'di; zi'eh; zi'ei; zhei
input=94343 -> 23 segmentations: xi'e'ge; xi'e'he; xi'di'e; xi'eh'e; xi'ei'e; xi'die; yi'e'ge; ...; zhe'ge; zhe'he; zhei'e
```

`94343` 共 **23** 种合法切分，Lua 与 Python 结果逐条一致 → M1 ✅。

---

## 3. M2 —— 音节候选（`lua_translator`）

纯数字段交由 `t9_translator.lua`：对 `prefix_choices()` 返回的每个「首音节且剩余仍可切分」
的精确拼音产出候选，`comment` 附完整切分预览。

empty 模式实测（`transcripts/run_empty.txt` 对应控制台转录）：

```
候选 12 条：
  [ 0]* text=''  comment="xi'343 | 后续(6)：e'ge / e'he / di'e"
  [ 1]* text=''  comment="yi'343 | 后续(6)：e'ge / e'he / di'e"
  [ 2]* text=''  comment="zi'343 | 后续(6)：e'ge / e'he / di'e"
  [ 3]* text=''  comment="xie'43 | 后续(2)：ge / he"
  [ 4]* text=''  comment="zhe'43 | 后续(2)：ge / he"
  [ 5]* text=''  comment="zhei'3 | 后续(1)：e"
  [ 6]  text='写个' ...（以下为 script_translator 的词典候选）
```

前 6 条是 `t9_syllable` 音节候选（text 为空，拼音藏在 comment），后 6 条是词典候选 → M2 ✅。

---

## 4. M3 —— 点选拦截（核心机制）

### 4.1 机制

- schema 用 **`fluid_editor`**（而非 `express_editor`）。`fluid_editor` 的 `_auto_commit=false`，
  点选候选时引擎自己的 `OnSelect` 不会抢先把整段提交。
- 在 `select_notifier` 回调里：引擎先跑 `OnSelect`（会 `seg.Close()`，并在 `Forward()` 后给
  composition 尾部塞一个空 segment，导致 `back().selected_candidate` 为 nil），因此回调里改为
  `scan_selected_candidate()`——从后往前扫 composition，找最近一个「选中了 `t9_syllable` 候选」
  的 segment，从中还原精确拼音 `syl`。
- 改写：`newinput = head .. syl .. "'" .. rest`（`rest` 为尚未消费的剩余数字）。

### 4.2 三种候选 text 模式的实测结果

`transcripts/run_empty.txt` / `run_text.txt` / `run_marker.txt` 转录（点选 index=4 的 `zhe`）：

```
[text]   94343 --select(zhe)--> input="zhe'43" commit='' rewrite_ok=True leak=False
[empty]  94343 --select(zhe)--> input="zhe'43" commit='' rewrite_ok=True leak=False
[marker] 94343 --select(zhe)--> input="zhe'43" commit='' rewrite_ok=True leak=False
```

三种模式都能把 `94343` 改写成 `zhe'43`，且 `commit` 为空（无自动上屏）→ M3 ✅。

empty 模式点选前后的完整对照（真实控制台转录）：

```
改前 input='94343'  preedit='94343'
  [ 4]* text=''  comment="zhe'43 | 后续(2)：ge / he"      ← 点中它
  select() 返回 True
改后 input    = "zhe'43"
改后 preedit  = "zhe'43"
commit 泄漏   = ''
候选 4 条： 这个 / 折合 / 这和 / 这
```

### 4.3 零泄漏的实证（直接 `commit_composition` 对照探针）

不能只看「点选后 commit 为空」——还要证明「如果宿主真的调用提交，会不会漏出候选文本」。
用 `commit_composition` 直接提交三种模式：

```
[text]   preview='xi'           直接提交='xi'
[marker] preview='\x01xi\x01'   直接提交='\x01xi\x01'
[empty]  preview=''             直接提交=''          ← 完全无泄漏
点选 zhe 后提交：三种模式都是 '这个'
```

**结论**：候选 text 留空（empty 模式）时，预编辑区与提交文本都不含任何候选文本 → 零泄漏。
marker 模式若被直接提交会漏出 `\x01` 标记；而 librime-lua 暴露的 `Context` 包装**没有
`set_commit_text`**，无法在 `commit_notifier` 里剥离标记，只能靠宿主层或改用 empty 模式。

### 4.4 键盘路径也没有泄漏

在本方案下，键盘 space/Return **不会 commit**，而是选中高亮候选触发 `select_notifier` 改写
（实测 `Return` → `input` 变 `xi'343`）。故键盘路径同样不产生文本泄漏。

---

## 5. M4 —— 混合接力

改写后的 `zhe'43` = 已确认音节 `zhe` + 撇号 + 剩余数字 `43`。要让它被 `script_translator`
正确命中，**schema 的 speller 必须配 `delimiter: " '"`**。

`transcripts/run_empty.txt` 转录（三条全部 PASS）：

```
[M4 PASS] input=zhe'43 want=这个 -> cands=['这个', '折合', '这和', '这']
[M4 PASS] input=zhe'94 want=这西 -> cands=['这西', '这']
[M4 PASS] input=xi'34  want=西地 -> cands=['西地', '希地', '西递', '西']
```

`delimiter` 探针（同一编译，直接 `set_input` 对照）：

```
input='94343'   -> 12: xi | yi | zi | xie | zhe | zhei
input="zhe'43"  ->  4: 这个 | 折合 | 这和 | 这
input='zhe43'   ->  4: 这个 | 折合 | 这和 | 这
input="zhe'ge"  ->  2: 这个 | 这
input='zhege'   ->  2: 这个 | 这
input="zhe'4"   ->  4: 这个 | 折合 | 这和 | 这
```

并且 M3→M4 是同会话内直接接力（点选后 input 即变 `zhe'43`，候选立刻出「这个」）→ 整条
链路 M1→M2→M3→M4 ✅。

---

## 6. 兜底：`lua_processor` 按键循环切分

不依赖点选：输入纯数字时按 Tab/F2，在全部合法切分间循环并把 `context.input` 改写为精确拼音。
`t9_cycle_source` 始终保留原始数字串，另存 `t9_cycle_last` 用于识别自身输出，从而支持连续循环。

`transcripts/run_empty.txt` 转录（Tab ×8）：

```
[processor] Tab 循环结果：["xi'e'ge", "xi'e'he", "xi'di'e", "xi'eh'e", "xi'ei'e", "xi'die", "yi'e'ge", "yi'e'he"]
```

共 23 种切分可循环 → ✅。另有对照：真正逐键敲 `94343`（`process_key` 数字键，非 `set_input`）
结果与 `set_input` 一致（`transcripts/run_*.txt` 中 `[typed] 94343 -> input='94343'`）。

---

## 7. 最终推荐方案（移植基线）

1. schema：`engine.processors` 用 **`fluid_editor`**；speller 配 `delimiter: " '"`；
   `filters: []`（**必须去掉 `uniquifier`**，见踩坑 §8）。
2. `t9_translator.lua`：纯数字段 → 首音节候选，候选 **text 留空**，拼音信息放 comment。
3. `t9_core.lua` 的 `select_notifier`：`scan_selected_candidate()` 扫 composition 找被点中的
   `t9_syllable` segment，从 comment 还原 `syl`，改写 `input = head .. syl .. "'" .. rest`。
4. 宿主（Trime/小狼毫）UI：候选 text 为空，需用 **comment** 渲染音节标签；点选后不自动上屏，
   由后续确认动作（如再按 space/Return，或直接点词候选）上屏。

---

## 8. 移植 Trime（Android）注意事项

- **必须用 `fluid_editor`**：`express_editor` 的 `_auto_commit=true`，引擎 `OnSelect` 会抢在
  lua 回调之前 Commit，改写来不及。rime-ice 官方 `t9.schema.yaml` 用 `express_editor` 也能改写，
  是因为其被选 segment 的 `end` ≠ `input` 长度；本原型候选覆盖整段数字，故必须 `fluid_editor`。
  **代价**：点选音节后不再自动上屏，需要额外的确认动作。
- **delimiter 必须配**：`speller/delimiter: " '"`，否则改写出的 `zhe'43` 只命中撇号前的音节。
- **去 `uniquifier`**：empty 模式下所有音节候选 text 都是 `""`，`uniquifier` 会把它们合并成 1 个，
  候选无法逐个点选。
- **lua 环境**：Android 侧需自行打包 librime-lua，并保证 `require("t9_core")` 可解析
  （模块路径/打包方式与小狼毫可能不同）。
- **候选渲染**：候选 text 留空时 IME 需改用 comment 渲染标签，否则候选条空白。
- **无法改写 commit 文本**：librime-lua 的 `Context` 包装无 `set_commit_text`。若坚持使用
  marker 文本方案，必须在宿主层剥离标记；本原型推荐直接用 empty 模式规避。
- marker 模式在真实 Android 宿主里是否会被 `commit_composition`、是否会显示 `\x01`，
  **本原型未测**（引擎层已实测，宿主层行为待 Trime 侧确认）。

---

## 9. 踩坑记录

1. **stale compiled schema**：改 `*.schema.yaml` / lua 后必须**重新 deploy**；`out/user/build/`
   会缓存编译产物，不重编会一直跑旧方案。harness 的 `all` 已内置「先 deploy 再另起进程 run」。
2. **`default.yaml` 会被移入 trash**：Rime 1.13 起用户目录下的 `default.yaml` 部署时被移走，
   必须用 `default.custom.yaml` 打补丁才生效。
3. **`cand.end` 是 Lua 关键字**：字段访问要用 `cand["end"]` / `seg["_end"]`，直接 `cand.end` 报语法错。
4. **`Candidate` 构造函数**：`Candidate(type, start, end, text, comment)` 传的是结构体，注意
   `seg._end or seg["end"]` 的兼容写法。
5. **keysym 编码**：`process_key` 用 X11 keysym（`Tab=0xFF09`、`F2=0xFFBF`、`Return=0xFF0D`、
   数字/字母用 ASCII），不是虚拟键码。
6. **`9434 ≠ zhe'ge`**：`zhe'ge` 的数字是 `94343`；探针里输入 `9434` 对应 `xi'di` 等，
   不要混用。
7. **`candidate_list_begin` 只做 memset**：不取首个候选，必须先 `candidate_list_next()` 再读
   `it.candidate`，否则会多记一个零值空候选、下标整体错位。
8. **`Forward()` 会清空 `back()` 的 selected candidate**：引擎 `OnSelect` 里
   `Segmentation::Forward()` 给尾部 push 一个空 segment，导致回调里
   `context:get_selected_candidate()` 为 nil，必须改为扫描 composition（本原型的
   `scan_selected_candidate`）。
9. **`uniquifier` 合并空文本候选**：empty 模式下 6 个音节候选 text 全为 `""`，被合并成 1 个，
   M3 必然失败。去掉 `uniquifier`（`filters: []`）后正常。
10. **缺 `delimiter` 时撇号被当音节中止点**：无 `delimiter` 时 `zhe'43` 只命中「这」；
    加上 `delimiter: " '"` 后 `zhe'43` → 这个/折合/这和/这。
11. **deployer 与 engine 不能同进程**：编译与运行必须分进程，否则状态互相干扰。

---

## 10. 文件清单

```
t9-syllable-prototype/
├── harness.py                 # 全流程 harness（ctypes 调 rime.dll，M1~M4 + 兜底 + 对照）
├── REPORT.md                  # 本报告
├── rime/                      # 方案源码（会被同步进 out/user/）
│   ├── default.custom.yaml    # 只挂 t9prot、page_size=9、F4 切换
│   ├── t9prot.schema.yaml     # fluid_editor + delimiter + filters:[]（关键三处）
│   ├── t9prot.dict.yaml       # 迷你词典（拼音编码）
│   └── lua/
│       ├── t9_core.lua        # 音节树/枚举/首音节选择/select_notifier 改写
│       ├── t9_translator.lua  # 纯数字 → 音节候选
│       └── t9_processor.lua   # 兜底 Tab/F2 循环切分
├── transcripts/
│   ├── run_empty.txt          # 最终推荐模式转录（三机制+兜底）
│   ├── run_text.txt
│   └── run_marker.txt
└── out/                       # 运行产物（沙箱用户目录、编译缓存、日志），非源码
    ├── user/                  # 沙箱用户目录（含 build/t9prot.table.bin）
    ├── log/                   # librime 运行日志 + t9_debug.log
    └── syllables.txt          # 音节库快照（424 条）
```

**未在真实用户目录或真实 Trime 上验证**：本报告结论仅限 librime 引擎层；
宿主层（小狼毫/Trime 的 UI 渲染、提交时机）需在目标平台另行确认。
