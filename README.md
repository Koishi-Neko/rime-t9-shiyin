# 九宫拾音 rime-t9-shiyin

给 **同文输入法（Trime）+ 雾凇拼音九宫格** 带来商业输入法级体验的开源增强包。

核心目标：把百度输入法（小米版）九宫格上那些"用了就回不去"的交互，在开源 Rime 生态里复现。

## 功能

| 功能 | 状态 | 说明 |
|---|---|---|
| **音节筛选**（拾音） | ✅ 已移植进 t9 方案（引擎层回归通过 + 真机验收，[剩余 Trime 侧确认项](schema/PORTING.md#8-trimeandroid侧待验证清单)） | 九宫格数字串 → 列出所有合法拼音切分（如 `94343` → `zhe`/`xie`/`zhei`…），点选音节锁定切分，预编辑改写为精确拼音继续接力。Rime 系九宫格长期缺失的能力，由 librime-lua 实现 |
| 删除键上滑清空 | ✅ | `swipe_up: Clear`（全选删除），原有左滑清空保留 |
| 空码标点侧栏 | ✅ | 键盘左列高频标点，输入中自动变为分词/翻页等功能，滑动扩展更多符号 |
| 数字键盘符号栏 | ✅ | 数字布局左列 `+ - * /` 等符号 |
| 分类符号面板 | ✅ | liquid keyboard 精简重排：常用(最近) / 中文 / 英文 / 数学 / 表情优先，左侧分类 + 右侧网格 |

## 原理

音节筛选不依赖任何引擎补丁，纯 librime-lua 实现：

1. `lua_translator` 对纯数字输入用「全拼合法音节前缀树」DFS 枚举所有切分，把可选首音节产出为候选
   （text = 音节如 `zhe`，comment = 短读法如 `zhe'43`）
2. `lua_filter` 把音节候选的跨度缩到「首音节末尾」，让引擎按 partial 选择处理（不自动提交）
3. 点选后经 `select_notifier` 扫描 composition 还原被点中的音节，将 `context.input` 从 `94343` 改写为 `zhe'43`
4. 引擎原生接力：字母按精确拼音、剩余数字继续 T9

完整技术验证（含真实转录与 11 条踩坑）见 [docs/syllable-prototype-report.md](docs/syllable-prototype-report.md)。
为什么移植时**没有**照原型改用 `fluid_editor`、音节候选怎么改 text 渲染、emoji 变体与
「文本框里出现 343」的排查结论，见 [schema/PORTING.md](schema/PORTING.md)。

## 目录

```
schema/t9.schema.yaml   雾凇九宫格 t9 方案（原包文件 + 5 处移植改动，可直接覆盖）
schema/PORTING.md       移植说明：改了哪些行、为什么、真机验收后的调整、Trime 侧待验证清单
lua/t9_syllable*.lua    挂进手机包 lua/ 目录的四个 lua（translator / processor / filter / core）
tools/harness.py        ctypes 直调 rime.dll 的无头测试底座（来自原型工程）
tools/harness_real.py   用真实手机包 + 真实 rime_ice 词典跑回归（base/port 对照）
docs/                   原型验证报告
```

## 使用

把 `lua/t9_syllable*.lua` 拷进手机包（或 Trime 配置目录）的 `lua/` 下，
`schema/t9.schema.yaml` 覆盖包根目录的同名文件，然后重新部署即可。

引擎层回归（需要本机装了小狼毫，脚本用它的 `rime.dll`；全程不碰 `%APPDATA%\Rime`）：

```bash
python tools/harness_real.py all --variant port                # 移植后（默认 text 渲染模式）
python tools/harness_real.py all --variant port --mode empty   # 空 text 备选模式
python tools/harness_real.py all --variant base                # 原包基线（同一条命令，便于逐行对照）
```

沙箱与编译产物默认落在原型工程的 `../rime-lexicon/t9-syllable-prototype/out/realtest/`，
转录写到该工程的 `transcripts/`；路径可用 `T9_WORKSPACE` / `T9_PKG` / `T9_TRANSCRIPTS` 覆盖。
注意对照要在 deploy 之后的第一次 run 里看：同一沙箱重复 run 会被用户词典学习影响候选顺序。

## 致谢与许可

- 主题基底：[同文风·增强版](https://github.com/SivanLaai/rime-pure) by SivanLaai（MIT License）
- 输入方案基底：[雾凇拼音 rime-ice](https://github.com/iDvel/rime-ice) by iDvel 及贡献者（GPL-3.0）
- 本项目整体以 [GPL-3.0](LICENSE) 发布
