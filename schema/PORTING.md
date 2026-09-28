# 音节筛选移植说明（t9.schema.yaml）

本文说明「九宫拾音」的音节筛选功能怎么移植进**雾凇拼音手机九宫格包**（`rime-ice-t9-phone` v3.2.2，
仓输入法/元书输入法用的那份），相对原包改了哪些行、为什么这么改、真机验收后为什么把候选渲染
从「空 text」改成「text = 音节」，以及 Trime（Android）侧还需要确认什么。

- 基线文件：`手机同步/rime-ice-t9-phone-v3.2.2.zip` → `rime-ice-t9-phone-main/t9.schema.yaml`
  （`__include: rime_ice.schema.yaml:/`，主九宫格方案，实测在用户手机 Trime 3.3.x 上正常工作）
- 本仓库产物：`schema/t9.schema.yaml`（完整文件，可直接覆盖）+ `lua/t9_syllable*.lua`
- 引擎层回归：`tools/harness_real.py`（ctypes 直调小狼毫 `rime.dll`，librime 1.13.1）
- 转录（`t9-syllable-prototype/transcripts/`）：
  - `run_realpackage.txt` — **移植后 · text 渲染模式（真机默认）**
  - `run_realpackage_empty.txt` — 移植后 · 空 text 备选模式（A/B 对照，真机验收前的老默认）
  - `run_realpackage_base.txt` — 原包基线（同一条命令，用于逐行对照）

> ⚠️ 对照要在 **deploy 之后的第一次 run** 里看。同一个沙箱重复 run 会写入用户词典/predict
> 学习结果，词典候选的相对顺序会变（例如 `94343` 的首个词典候选从「这个」漂到「洗爹」）。
> `harness_real.py deploy` 会重建沙箱，所以 `all` 每次都是干净的。

---

## 1. 改了哪些行

相对原包 `t9.schema.yaml` **只有 5 处改动**，其余逐字一致。

### 1.1 `engine/processors`：新增 Tab/F2 兜底处理器（放首位）

```yaml
  processors:
+   # 九宫拾音：Tab / F2 循环切分兜底（纯数字且多种切分时才接管按键，其余 kNoop 放行）
+   - lua_processor@*t9_syllable_cycle
    - ascii_composer
```

### 1.2 `engine/translators`：音节候选翻译器（放首位）

```yaml
  translators:
+   - lua_translator@*t9_syllable
    - predict_translator
```

位置 + `quality = 100` 双保险：librime 的候选排序见 `src/rime/candidate.cc`
（同一 start 比 end，end 大者优先；再比 quality），把音节候选按整段产出即可排到词典候选前面。

### 1.3 `engine/filters`：末尾加一道 filter，并去掉 `uniquifier`

```yaml
  filters:
    - simplifier@emoji
    - simplifier@prediction_simplify
    - simplifier@traditionalize
+   - lua_filter@*t9_syllable_filter     # 把音节候选的 end 缩到首音节末尾（§3）
-   - uniquifier # 去重                  # 必须去掉：它会把 text 相同的音节候选合并成一个
```

### 1.4 `speller`：显式写出 delimiter

```yaml
  speller:
+   delimiter: " '"      # 与 rime_ice 同值（原本靠 __include 继承）。zhe'43 需要撇号被 prism 接受
```

> 实测：原包**本来就继承到了** `delimiter`（基线里 `zhe'43` → 这个/这和/折合 ✓），
> 这里只是把隐含依赖显式化，行为不变。

### 1.5 `emoji`：排除音节候选（隔离 opencc 派生变体，§5）

```yaml
+ emoji:                                  # 其余键（option_name/opencc_config/inherit_comment）继承 rime_ice
+   excluded_types: [ t9_syllable ]
```

---

## 2. 挂载的 Lua（`lua/` → 手机包 `lua/` 目录）

| 本仓库文件 | 挂钩 | 作用 |
|---|---|---|
| `lua/t9_syllable.lua` | `lua_translator@*t9_syllable` | 纯数字 + 多种切分时产出首音节候选 |
| `lua/t9_syllable_core.lua` | 被其它两个 require | 音节前缀树、DFS 枚举、select/commit 监听与 `context.input` 改写、Tab 循环 |
| `lua/t9_syllable_cycle.lua` | `lua_processor@*t9_syllable_cycle` | Tab / F2 在所有合法切分间循环（不依赖点选的兜底） |
| `lua/t9_syllable_filter.lua` | `lua_filter@*t9_syllable_filter` | 把音节候选的 `end` 缩到首音节末尾，使其成为 partial 选择（§3） |

> 与原型工程的对应关系：原型的 `t9_core.lua / t9_translator.lua / t9_processor.lua`
> 分别改名为 `t9_syllable_core.lua / t9_syllable.lua / t9_syllable_cycle.lua`
> （避免与手机包自带的 `t9_*.lua` 未来重名），并新增 `t9_syllable_filter.lua`（§3）。
> 候选类型标记沿用原型的 `t9_syllable`。

放置方式：把 `lua/*.lua` 拷进手机包的 `lua/` 目录（与包自带的 `t9_preedit.lua`、
`t9_default_abbreviation_segmentor.lua` 同级），`schema/t9.schema.yaml` 覆盖包根目录的同名文件。

### 音节数据不重复维护

音节**数字码表**不写在 lua 里，运行时读取手机包自带的
`lua/t9_default_abbreviation_segmentor.lua` 的 `FULL_PINYIN_CODES`
（即 t9 主 prism 实际接受的数字拼写集合，344 个码）。读取路径依次探测
本文件所在目录 → 上一级 `lua/` → `package.path` → 相对路径；读不到时退化为「由字母表推导」。
lua 里只保留**字母表**（424 条，用于把数字码还原成精确拼音）。

实测日志（`run_realpackage.txt` 的 lua 段）：

```
[install] 音节树：344 个数字码（…/user_port/lua/t9_default_abbreviation_segmentor.lua），
          424 个可还原拼音；补入 0 个
```

「补入 0 个」= 424 条字母对应的数字码全部已在包内码表中（无遗漏、无冲突）。

### 候选排序策略

- 只有**纯数字段** + **≥2 种切分** + **首音节可选 ≥2 个**时才出音节候选；单一切分（如 `98`、`94`）直接出词典候选。
- 音节候选排在词典候选**前面**；词典候选部分与原包逐条一致（§9 实测）。

---

## 3. 关键设计：为什么**不用** `fluid_editor`

原型报告（`docs/syllable-prototype-report.md` §7/§8）的结论是「必须用 fluid_editor」，
前提是**音节候选覆盖整段输入**。移植到真实包时实测发现这条路会破坏现有行为，所以换了做法。

### 3.1 引擎机制（`librime` 源码 + 桌面实测）

`src/rime/engine.cc`：

```cpp
void ConcreteEngine::OnSelect(Context* ctx) {
  Segment& seg(ctx->composition().back());
  seg.Close();                                  // 若被选候选 end < 段 end，按 partial 截断该段
  if (seg.end == ctx->input().length()) {       // 整段被吃掉 → 视为输入完成
    seg.status = Segment::kConfirmed;
    if (ctx->get_option("_auto_commit"))        // express_editor=true / fluid_editor=false
      ctx->Commit();
    else
      ctx->composition().Forward();
  } else { ... }
}
```

`src/rime/segment.cc`（`Close()`）与 `src/rime/candidate.cc`（`compare()`）：

```cpp
void Segment::Close() { if (cand && cand->end() < end) { end = cand->end(); tags.insert("partial"); } }

int Candidate::compare(const Candidate& other) {
  int k = start_ - other.start_;  if (k) return k;      // start 小的在前
  k = end_ - other.end_;          if (k) return -k;     // end 大的在前（！）
  double qdiff = quality_ - other.quality_; ...         // 最后比 quality
}
```

推出两条互相打架的约束：

1. 想排在词典候选（覆盖整段）前面 → 音节候选必须**覆盖整段**（end 相同才轮到比 quality）；
2. 覆盖整段 → `OnSelect` 判定「输入完成」→ express_editor 直接 `Commit()`（composition 被清空），
   我们的 `select_notifier` 拿到的是空 context，改写无从下手；原型因此改用 fluid_editor
   （`_auto_commit=false`，不提交）。

### 3.2 fluid_editor 在真实包里的代价（实测）

| 场景 | 原包（express_editor） | 换 fluid_editor 后 |
|---|---|---|
| 点选词典候选「这个」 | `commit='这个'` ✅ | `commit=''`、input 仍是 `94343` ❌ |
| 点选词典候选「上」 | `commit='上'` ✅ | `commit=''` ❌ |

也就是**点词不再上屏**，手机端要额外一次确认。这属于「破坏现有行为」，不能接受。

### 3.3 采用的方案：整段产出 + filter 缩 end（partial 选择）

- `t9_syllable.lua`：候选按**整段**产出（满足约束 1，排在最前）。
- `t9_syllable_filter.lua`（filters 末位，菜单成型后）：把每个音节候选的 `end` 缩到「首音节末尾」。
  → 点选时 `Segment::Close()` 把该段截成 **partial 选择**，`seg.end != input.length()`，
  引擎**不提交**，`select_notifier` 从容把 `context.input` 从 `94343` 改写为 `zhe'43`。
- 词典候选一个字节都没动 → 仍然一按即上屏。
- `express_editor` 保持原样 → space/Return/光标/翻页等全部按键行为与原包一致。

实测（`run_realpackage.txt`）：

```
[port] 94343 音节候选 6 条：xi / yi / zi / xie / zhe / zhei（text = 音节，comment = "zhe'43" 这类短读法）
       词典候选 411 条：这个 / 这和 / 折合 / 协和 / 一叠 …（与原包逐条一致）
点选 #4（zhe）→ select=True  input="zhe'43"  preedit="zhe'43"  commit='' ← 不上屏、不泄漏
              候选立刻变成 29 条：这个 / 这和 / 折合 / …（词典候选接力，preview='这个'）
点选 这个 → commit='这个' ✅
```

### 3.4 兜底：万一 partial 没生效

`t9_syllable_core.lua` 里另外挂了 `commit_notifier`：如果引擎抢先整段提交了，
此时 composition 仍在、`c.input` 还是原数字串，就先暂存下来，等 `select_notifier` 用暂存值补写回
`zhe'43`。调试开关 `t9_syllable_no_partial` 可以让 filter 原样放行来验证这条路径：

```
[port] 补救路径 点选 zhe -> commit='zhe' input="zhe'43"   （text 模式下那一瞬间会先把音节提交掉，见 §4）
```

### 3.5 Tab 兜底

`lua_processor@*t9_syllable_cycle` 放 processors 首位，只在两种情况下消费按键：

1. 输入是纯数字且存在 ≥2 种切分（与 translator 同一门槛）；
2. 当前输入就是本模块上一轮写出来的串（继续循环）。

其余一律返回 kNoop(2) 放行。实测在原包 Tab 绑定（`default.yaml`：`Tab → Shift+Right` 光标移动）下：

| | 原包 | 移植后 |
|---|---|---|
| `94343` + Tab | input 不变，preedit 在 `94343`/`943 43` 间晃（光标移动） | 循环切分：`xi'e'ge → xi'e'he → xi'di'e → … → zhei'e`（23 种） |
| 非歧义输入 + Tab | 光标移动 | 光标移动（未接管，返回 kNoop） |

---

## 4. 候选渲染：text = 音节、comment = 短读法（真机验收后的决定）

### 4.1 为什么改

第一版沿用原型的「候选 text 留空、信息全放 comment」。真机验收反馈：

> 音节候选机制工作正常（顺序、数量、点选改写都对），但 Trime 候选条上只渲染 comment，
> 用户看到一长串 `xi'343 | 后续(3): e'ge / di'e / die`，完全看不出是可点选的音节按钮。

所以改成：

| | 现在（默认） | 旧（空 text 备选，`t9_syllable_empty_text` 打开时） |
|---|---|---|
| 候选 text | 音节本身：`xi` / `zhe` / `zhei` | `""` |
| 候选 comment | 这个候选定下来的写法：`xi'343` / `zhe'43` / `zhei'3` | 同 |
| 候选条 | 直接显示可点的音节按钮 `zhe`，右侧浅色小字 `zhe'43` | 只剩那串浅色注释 |
| 长文案 | 已删除（不再拼「后续(n)：e'ge / di'e / die」） | — |

comment 之所以放「完整读法」而不是只放剩余数字：rime-ice 的 t9 方案里**第一行 preedit 是拿候选
comment 渲染的**（`t9.schema.yaml` 的 `translator/comment_format` 注释、`t9/isDisplayOriginalPreedit: false`），
包内词典候选的 comment 也正是它们的拼读（`zhe ge`）。这样高亮音节候选时 preedit 行显示 `zhe'43`，
信息完整且够短。

### 4.2 text 模式为什么仍然不泄漏

上一版的顾虑是「候选 text 非空 → 宿主一旦提交整段就把拼音当文字打出去」。现在不成立，因为
§3.3 的 partial 机制让音节候选被点选时**引擎根本不提交**，实测：

```
[port:text] 逐键敲 94343 每键 commit 非空次数=0；点选音节候选 -> commit='' input="zhe'43"
```

即使 partial 机制失效走到 §3.4 的补救路径，泄漏的也只是「音节本身」（如 `zhe`），
而不是整串数字，且输入会被补写回 `zhe'43`。要回到「零文本」行为，把 `t9_syllable_empty_text`
打开即可（代价就是真机候选条又会变成一长串注释）。

### 4.3 相关调试开关（都只由宿主 set_option 打开，不出现在方案选单里）

| 开关 | 作用 |
|---|---|
| `t9_syllable_empty_text` | 候选 text 留空（旧默认，零文本模式） |
| `t9_syllable_no_partial` | filter 不做 partial 缩短，用于验证 §3.4 补救路径 |
| `t9_syllable_no_rewrite` | 只跳过 input 改写，用于观察 partial 瞬间的引擎状态（§6） |
| `t9_syllable_off` | 整体停用音节候选，用于 A/B 对照 |

---

## 5. emoji / symbol 变体候选的根因与对策

第一版 text 模式下，`94343` 的前几位会多出 `ξ`、`Ξ`，`74264` 会多出 `π`、`Π`。

**根因（文件级证据）**：手机包自带的 `opencc/others.txt` 里有以**音节**为键的条目：

```
1185:  xi      xi ξ Ξ
1187:  pi      pi π Π
1156:  克西     克西 ξ Ξ
```

`emoji.json` 的转换链是 `{emoji.txt, others.txt}`，schema 里 `simplifier@emoji` 用的就是它。
librime 的 `Simplifier`（`src/rime/gear/simplifier.cc`）对每个候选的 **text** 做 opencc 转换，
命中多结果（`xi / ξ / Ξ`）时保留原文并**额外派生** shadow 候选：

```cpp
bool Simplifier::Convert(const an<Candidate>& original, CandidateQueue* result) {
  if (excluded_types_.find(original->type()) != excluded_types_.end()) return false;   // ← 按 type 排除
  vector<string> forms;
  success = opencc_->ConvertWord(original->text(), &forms);
  ...  // forms[i] != original->text() 的都作为新候选派生
}
```

音节候选的 text 从空变成 `xi` 之后正好命中这 5 个键（`xi`、`pi`、`chi`、`mu`、`nu`），
于是每个都派生一串希腊字母变体，插在音节候选之间。

**对策**：给 `emoji` 段加 `excluded_types: [ t9_syllable ]`（§1.5）。`Simplifier::Convert`
第一步就按候选 type 过滤，一行配置隔离全部 5 个音节，对其它候选零影响。实测：

```
（改前）94343 前 8 候选：xi  ξ  Ξ  yi  zi  xie  zhe  zhei
（改后）94343 前 8 候选：xi  yi  zi  xie  zhe  zhei  这个  这和
（改后）74264 前 8 候选：pi  qi  ri  si  pia  qia  sha  qiang     ← 无 π/Π
```

**顺带说明（不是我们引入的）**：`244`、`68` 这类输入里仍能看到 `χ/Χ`、`μ/Μ/ν/Ν`。
它们来自词典里 **text 本身就是拼音**的英文类词条（melt_eng 的 `chi`/`mu`/`nu`，comment 为空），
被同一个 emoji 词典转换而来。原包基线里一模一样（同名转录 `run_realpackage_base.txt`：

```
[base] input=244 前10候选=['吃','持','迟',…] 全表希腊字母=['χ','Χ']
[base] input=68  前10候选=['女','♀','目',…] 全表希腊字母=['μ','Μ','ν','Ν']
```

与音节候选无关，属原包既有行为，未做处理。

---

## 6. 真机「文本框里出现 343」的排查结论（引擎无泄漏）

真机反馈：输入 `94343` 后 App 文本框里出现了 `343`，而 preedit 仍显示完整 `94343`。
用 harness 在引擎层逐态测量（`scenario_leak`）：

| 状态 | commit | commit_text_preview |
|---|---|---|
| 逐键敲 `9`→`4`→`3`→`4`→`3`（每键都查） | 5 次全为 `''` ✅ | 末态 `343`（空 text 模式）/ `xi343`（text 模式） |
| `set_input("94343")` | `''` ✅ | 同上 |
| 点选音节候选 `zhe`（正常路径） | `''` ✅ | `这个`（已改写，干净） |
| 点选音节候选（`t9_syllable_no_rewrite` 诊断，模拟改写没跑） | `''` ✅ | `个`（空 text）/ `zhe个`（text）；preedit `43` / `zhe43` |

**结论**：

1. **引擎层的提交始终为空**：无论是打字过程还是点选音节候选，`commit` 事件一次都没发生过（5+2 个状态全空）。
2. `343` 的来源是 **`commit_text_preview`**（`Context::GetCandidatePreview()`）：高亮候选是音节候选时，
   它只覆盖首音节，于是引擎把这个候选的 text 加上**剩余未确认数字**拼成「如果现在提交会打出什么」——
   空 text 模式下正好是 `343`（= `""` + `343`），text 模式下是 `xi343`（= `xi` + `343`）。
   这与截图里的 `343` 完全吻合。
3. 真机截图里 `343` 出现在 App 文本框，而 App 自己的 preedit 行仍显示 `94343`（原包用候选 comment 渲染
   preedit）→ **是宿主把这个 preview（或 composition 的等价值）当待上屏文本用了**，属于宿主侧行为，
   不是引擎提交泄漏。
4. 正常路径下这个中间态不可见：partial 选择和我们的 input 改写发生在**同一次** `select_candidate`
   调用内，宿主拿到的是改写后的状态（实测 preview 已是 `这个`）。
5. 若想在宿主侧彻底避免看到这串数字，可选做法（都在宿主/主题侧，不需要改 lua）：
   以 preedit + 候选条为准渲染、不要把 `commit_text_preview` 同步进文本框；
   或把 `t9_syllable_no_rewrite` 类的诊断开关关掉（默认关）。

---

## 7. 已知行为变化（相对原包）

1. **候选不再按 text 去重**（去掉 `uniquifier`）：实测 §9 的输入没有出现重复候选；
   但理论上词典里若有同 text 候选，现在会都显示（音节候选也必须靠这一点才能逐个点选）。
2. **Tab 在「数字串有多种切分」时会循环切分**，不再移动光标；其他时候与原包一致。
3. **空格在高亮音节候选时是「锁定音节」**（改写 input），不再是提交那一个候选；
   紧接着再按空格即提交词候选（实测 `洗爹`）。
4. 音节候选的 text 是音节（如 `zhe`）、comment 是短读法（如 `zhe'43`）；空 text 模式仍可用开关切回（§4.3）。
5. 点选音节候选后**不出词**、preedit 变成 `zhe'43`，需要再点/再选一次词候选才上屏 —— 这是「音节筛选」本身的交互。
6. 音节候选高亮时 `commit_text_preview` 会含剩余数字（§6），宿主若把它当待上屏文本会看到 `xi343`（旧空 text 模式为 `343`）。

---

## 8. Trime（Android）侧待验证清单

引擎层（桌面 librime 1.13.1）已全部实测通过，真机也确认了候选顺序/数量/点选改写；下面这些仍值得确认：

1. **候选渲染（已按真机验收改过）**：text = 音节、comment = 短读法，见 §4；再确认候选条上
   `zhe` + `zhe'43` 的字号/截断是否可读。
2. **preedit 行**：原包 `t9/isDisplayOriginalPreedit: false`（用候选 comment 渲染第一行），
   高亮音节候选时第一行会显示 `zhe'43`；若嫌重复或过长，可把 `t9_syllable.lua` 里
   `local comment = ...` 换成只放剩余数字（如 `→ 43`）。
3. **`commit_text_preview`**：确认 Trime 不会把它当待上屏文本同步进 App 文本框（§6）；
   若会，优先在宿主侧改渲染来源，而不是改 lua。
4. **点选后刷新**：点音节候选后 composition 变成 partial 选择（preedit = `zhe'43`），
   确认 Trime 会正确刷新候选条与预编辑区（不会把 `43` 当独立一段卡住）。
5. **手势**：长按/上滑/滑动选词等手势对音节候选（text 短、comment 稍长）的排版影响。
6. **librime/librime-lua 版本差异**：本方案依赖两个引擎行为 —— `Segment::Close()` 的 partial 截断、
   `Candidate::compare()` 的排序（都属 librime 本体，与宿主无关）；改写依赖
   `select_notifier` + `comp:toSegmentation():get_segments()`（真机已验证可用）。
   若某宿主两者都不可用，可用 `t9_syllable_no_partial` 验证补救路径是否生效。
7. **性能**：数字串较长时 DFS 有 200 条 / 20000 步上限；音节树加载依赖读包内 lua 文件，
   读不到时日志会显示「LETTERS(回退：未读到包内码表)」，功能仍可用（码表退化为字母表推导）。
8. **兜底键位**：手机键盘没有 Tab/F2，`t9_syllable_cycle` 主要服务桌面/硬件键盘宿主。
9. **`page_size`**：`default.yaml` 是 10，本例音节候选最多 6 条，不会占满第一页（门槛已限制为「多种切分」时才出）。

---

## 9. 回归证据与复现

`tools/harness_real.py` 把整包解压进沙箱用户目录（**不碰 `%APPDATA%\Rime`，不跑 WeaselDeployer**），
用 `rime.dll` 编译后另起进程跑场景。`variant=base` 是原包、`variant=port` 是移植后，两份转录可逐行对照。

| 输入 | 原包首候选 | 移植后（text 模式） |
|---|---|---|
| `94343` | 这个 | 6 条音节候选 `xi/yi/zi/xie/zhe/zhei` → 这个 |
| `74264` | 上 | 9 条音节候选 → 上 |
| `98` | 无 | 无（单一切分 → 不出音节候选） |
| `636` | 们 | 5 条音节候选 → 们 |
| `26426` | 拨号 | 5 条音节候选 → 拨号 |
| `48268` | 花木 | 4 条音节候选 → 花木 |

- **词典候选部分与原包逐条一致**：`94343` 音节候选后紧跟 `这个/这和/折合/协和/一叠/写个/…`，
  与 base 完全相同；总数差值 = 音节候选条数（`94343` 411→417、`74264` 260→269、`98` 268→268、
  `636` 69→74、`26426` 148→153、`48268` 136→140），即去掉 `uniquifier` 后这些输入**没有**多出重复候选。
- 点选词典候选仍上屏：`94343` 点「这个」→ `commit='这个'`；`74264` 点「上」→ `commit='上'`。
- 空格/回车：`94343` + space（高亮音节候选）→ 锁定为 `xi'343`；再 space → `commit='洗爹'`；
  `94343` + Return → `commit='94343'`（与原包一致，走 rime_ice 的 `Return: commit_raw_input`）。
- 逐键敲 `94343`（`process_key`，不是 `set_input`）与 `set_input` 结果一致。
- librime ERROR 日志中**无 Lua 报错**。

复现命令：

```bash
# 在仓库根目录
python tools/harness_real.py all --variant port --mode text    # 默认渲染模式（写 run_realpackage.txt）
python tools/harness_real.py all --variant port --mode empty   # 空 text 备选模式
python tools/harness_real.py all --variant base                # 原包基线（坚持同一条命令，便于对照）
```

沙箱/日志/编译产物默认落在原型工程的 `../rime-lexicon/t9-syllable-prototype/out/realtest/`，
转录写到该工程的 `transcripts/`；路径可用 `T9_WORKSPACE` / `T9_PKG` / `T9_TRANSCRIPTS` 覆盖。
