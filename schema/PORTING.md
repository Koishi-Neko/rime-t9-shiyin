# 音节筛选移植说明（t9.schema.yaml）

本文说明「九宫拾音」的音节筛选功能怎么移植进**雾凇拼音手机九宫格包**（`rime-ice-t9-phone` v3.2.2，
仓输入法/元书输入法用的那份），相对原包改了哪些行、为什么这么改、以及 Trime（Android）侧还需要确认什么。

- 基线文件：`手机同步/rime-ice-t9-phone-v3.2.2.zip` → `rime-ice-t9-phone-main/t9.schema.yaml`
  （`__include: rime_ice.schema.yaml:/`，主九宫格方案，实测在用户手机 Trime 3.3.x 上正常工作）
- 本仓库产物：`schema/t9.schema.yaml`（完整文件，可直接覆盖）+ `lua/t9_syllable*.lua`
- 引擎层回归：`tools/harness_real.py`（ctypes 直调小狼毫 `rime.dll`，librime 1.13.1），
  转录见 `t9-syllable-prototype/transcripts/run_realpackage.txt`（空 text 推荐模式）、
  `run_realpackage_text.txt`（text 模式 A/B）、`run_realpackage_base.txt`（原包基线对照）

---

## 1. 改了哪些行

相对原包 `t9.schema.yaml` **只有 4 处改动**，其余逐字一致。

### 1.1 `engine/processors`：新增 Tab/F2 兜底处理器（放首位）

```yaml
  processors:
+   # 九宫拾音：Tab / F2 循环切分兜底（纯数字且多种切分时才接管按键，其余 kNoop 放行）
+   - lua_processor@*t9_syllable_cycle
    - ascii_composer
    ...
    - express_editor        # 保持原样，**不是** fluid_editor（见 §3）
```

### 1.2 `engine/translators`：音节候选翻译器（放首位）

```yaml
  translators:
+   - lua_translator@*t9_syllable
    - predict_translator
    - punct_translator
    - script_translator
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
-   - uniquifier # 去重                  # 必须去掉：它会把 text 为空的音节候选合并成一个
```

### 1.4 `speller`：显式写出 delimiter

```yaml
  speller:
    alphabet: ...
    initials: ...
+   delimiter: " '"      # 与 rime_ice 同值（原本靠 __include 继承）。zhe'43 需要撇号被 prism 接受
    algebra: ...
```

> 实测：原包**本来就继承到了** `delimiter`（基线里 `zhe'43` → 这个/这和/折合 ✓），
> 这里只是把隐含依赖显式化，行为不变。

---

## 2. 挂载的 Lua（`lua/` → 手机包 `lua/` 目录）

| 本仓库文件 | 挂钩 | 作用 |
|---|---|---|
| `lua/t9_syllable.lua` | `lua_translator@*t9_syllable` | 纯数字 + 多种切分时产出首音节候选（text 留空，拼音/预览放 comment） |
| `lua/t9_syllable_core.lua` | 被上面两个 require | 音节前缀树、DFS 枚举、select/commit 监听与 `context.input` 改写、Tab 循环 |
| `lua/t9_syllable_cycle.lua` | `lua_processor@*t9_syllable_cycle` | Tab / F2 在所有合法切分间循环（不依赖点选候选的兜底） |
| `lua/t9_syllable_filter.lua` | `lua_filter@*t9_syllable_filter` | 把音节候选的 `end` 缩到首音节末尾，使其成为 partial 选择（§3） |

> 与原型工程的对应关系：原型的 `t9_core.lua / t9_translator.lua / t9_processor.lua`
> 分别改名为 `t9_syllable_core.lua / t9_syllable.lua / t9_syllable_cycle.lua`
> （避免与手机包自带的 `t9_*.lua` 未来重名，挂钩名也一并带上 `t9_syllable` 前缀），
> 并新增 `t9_syllable_filter.lua`（原型没有这道 filter，理由见 §3）。
> 候选类型标记仍沿用原型的 `t9_syllable`。

放置方式：把 `lua/*.lua` 拷进手机包的 `lua/` 目录（与包自带的 `t9_preedit.lua`、
`t9_default_abbreviation_segmentor.lua` 同级），`schema/t9.schema.yaml` 覆盖包根目录的同名文件。
打包/同步流程可用仓库里的 `tools/`（见 README）。

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

「补入 0 个」= 424 条字母对应的数字码全部已在包内码表中（无遗漏、无冲突），
即两套数据没有分叉。

### 候选排序策略

- 只有**纯数字段** + **≥2 种切分** + **首音节可选 ≥2 个**时才出音节候选；单一切分（如 `98`、`94`）直接出词典候选。
- 音节候选在词典候选**前面**，词典候选顺序与数量不算音节候选时与原包完全一致（§4 实测）。

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
[port] 94343 音节候选 6 条：xi / yi / zi / xie / zhe / zhei（text 全部为空）
       词典候选 411 条：这个 / 这和 / 折合 / 协和 / 一叠 …
点选 #4（zhe）→ select=True  input="zhe'43"  preedit="zhe'43"  commit='' ← 无泄漏、无上屏
              候选立刻变成 29 条：这个 / 这和 / 折合 / …（词典候选接力）
点选 这个 → commit='这个' ✅
```

### 3.4 兜底：万一 partial 没生效

`t9_syllable_core.lua` 里另外挂了 `commit_notifier`：如果引擎抢先整段提交了，
此时 composition 仍在、`c.input` 还是原数字串，就先暂存下来，等 `select_notifier` 用暂存值补写回
`zhe'43`。调试开关 `t9_syllable_no_partial` 可以让 filter 原样放行来验证这条路径：

```
[port] 补救路径 点选 zhe -> commit='' input="zhe'43"   （实测同样通过）
```

**为什么候选 text 留空**：即使某个宿主真的把那一下「空提交」送到输入法客户端，提交文本也是空串，
不会把拼音当文字打出去。这是零泄漏的保险（原型报告 §4.3 的结论，移植后沿用），
text 模式只作 A/B 调试用（`t9_syllable_text` 选项），实测 text 模式还会额外引出
`xi → ξ / Ξ`、`pi → π / Π` 这类 emoji/symbol 变体候选，故不建议用于手机。

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

## 4. 回归证据（真实包 + 真实 rime_ice 词典，librime 1.13.1）

`tools/harness_real.py` 把整包解压进沙箱用户目录（**不碰 `%APPDATA%\Rime`，不跑 WeaselDeployer**），
用 `rime.dll` 编译后另起进程跑场景。`variant=base` 是原包、`variant=port` 是移植后，两份转录可逐行对照。

| 输入 | 原包首候选 | 移植后 |
|---|---|---|
| `94343` | 这个 | 6 条音节候选 → 这个（词典部分一字不差） |
| `74264` | 上 | 9 条音节候选 → 上 |
| `98` | 无 | 无（单一切分 → 不出音节候选） |
| `636` | 们 | 5 条音节候选 → 们 |
| `26426` | 拨号 | 5 条音节候选 → 拨号 |
| `48268` | 花木 | 4 条音节候选 → 花木 |

- **候选总数差值 = 音节候选条数**：`94343` 411→417、`74264` 260→269、`98` 268→268、
  `636` 69→74、`26426` 148→153、`48268` 136→140。即去掉 `uniquifier` 后这些输入**没有**多出重复候选。
- 点选词典候选仍上屏：`94343` 点「这个」→ `commit='这个'`；`74264` 点「上」→ `commit='上'`（与原包一致）。
- 空格/回车：`94343` + space（高亮音节候选）→ 锁定为 `xi'343`；再 space → `commit='洗爹'`（词候选照常上屏）；
  `94343` + Return → `commit='94343'`（与原包一致，走 rime_ice 的 `Return: commit_raw_input`）。
- 逐键敲 `94343`（`process_key`，不是 `set_input`）与 `set_input` 结果一致。
- librime ERROR 日志中**无 Lua 报错**。

复现命令：

```bash
cd t9-syllable-prototype
python harness_real.py all --variant base          # 原包基线（≈20s 编译）
python harness_real.py all --variant port          # 移植后（默认 empty 模式）
python harness_real.py all --variant port --mode text
```

---

## 5. 已知行为变化（相对原包）

1. **候选不再按 text 去重**（去掉 `uniquifier`）：按 §4 实测，本节列举的输入没有出现重复候选；
   但理论上词典里若有同 text 候选，现在会都显示（音节候选必须靠这一点才可逐个点选）。
2. **Tab 在「数字串有多种切分」时会循环切分**，不再移动光标；其他时候与原包一致。
3. **空格在高亮音节候选时是「锁定音节」**（改写 input），不再是提交那一个候选；紧接着再按空格即提交词候选（实测 `洗爹`）。
4. 音节候选 `text` 为空、信息在 `comment` 里：宿主必须能用 comment 渲染候选条（见 §6）。
5. 点选音节候选后**不出词**、preedit 变成 `zhe'43`，需要再点/再选一次词候选才上屏 —— 这是「音节筛选」本身的交互。

---

## 6. Trime（Android）侧待验证清单

引擎层（桌面 librime 1.13.1）已全部实测通过；下面这些只有真机才能确认：

1. **候选渲染**：候选 `text` 为空时，Trime 的候选条必须用 `comment` 显示 `zhe'43 | 后续(1)：ge`
   之类的标签，否则会是空白按钮。若 Trime 不支持，可改用 `t9_syllable_text` 选项
   （文字上屏风险见 §3.4），或把 comment 缩短成更适合候选条显示的文案。
2. **preedit 显示**：原包 `t9/isDisplayOriginalPreedit: false`（用候选 comment 拼 preedit）。
   音节候选的 comment 较长，真机上要看 preedit 是否可读；必要时精简 `t9_syllable.lua` 的 comment 文案
   （格式在 `t9_syllable_filter.lua` / `t9_syllable.lua` 的 `string.format` 处）。
3. **点选后刷新**：点音节候选后 composition 变成 partial 选择（preedit = `zhe'43`），
   确认 Trime 会正确刷新候选条与预编辑区（不会把 `43` 当独立一段卡住）。
4. **手势**：长按/上滑/滑动选词等手势对空 text 候选的行为（Trime 主题可能按 text 长度排版）。
5. **librime/librime-lua 版本差异**：本方案依赖两个引擎行为 ——
   `Segment::Close()` 的 partial 截断、`Candidate::compare()` 的排序。
   Trime 3.3.x 打包的 librime-lua 是否同版本需确认；若 partial 行为不同，
   §3.4 的补救路径会自动接管（可用 `t9_syllable_no_partial` 先在本机验证）。
6. **性能**：数字串较长时 DFS 有 200 条 / 20000 步上限，真机上确认没有可感知卡顿
   （音节树加载依赖读包内 lua 文件；若 Trime 的 io/工作目录受限导致读不到，
   日志会显示「LETTERS(回退：未读到包内码表)」，功能仍可用但码表退化为 424 条字母推导）。
7. **兜底键位**：手机键盘没有 Tab/F2，`t9_syllable_cycle` 主要服务桌面/硬件键盘宿主；
   若 Trime 侧需要，可把 `t9_syllable_cycle.lua` 里的按键换成宿主能发的事件。
8. **`page_size`**：`default.yaml` 是 10，音节候选最多 6 条（本例），翻页体验与原来一致；
   若某些输入音节候选较多，确认第一页不会被音节候选占满（门槛已限制为「多种切分」时才出）。
