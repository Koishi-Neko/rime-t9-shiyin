# 九宫拾音 rime-t9-shiyin

给 **同文输入法（Trime）+ 雾凇拼音九宫格** 带来商业输入法级体验的开源增强包。

核心目标：把百度输入法（小米版）九宫格上那些"用了就回不去"的交互，在开源 Rime 生态里复现。

## 功能

| 功能 | 状态 | 说明 |
|---|---|---|
| **音节筛选**（拾音） | ✅ 引擎层已验证 | 九宫格数字串 → 列出所有合法拼音切分（如 `94343` → zhe'ge / xi'die / zhei'e），点选音节锁定切分，预编辑改写为精确拼音继续接力。Rime 系九宫格长期缺失的能力，由 librime-lua 实现 |
| 删除键上滑清空 | ✅ | `swipe_up: Clear`（全选删除），原有左滑清空保留 |
| 空码标点侧栏 | ✅ | 键盘左列高频标点，输入中自动变为分词/翻页等功能，滑动扩展更多符号 |
| 数字键盘符号栏 | ✅ | 数字布局左列 `+ - * /` 等符号 |
| 分类符号面板 | ✅ | liquid keyboard 精简重排：最近 / 中文 / 英文 / 常用，左侧分类 + 右侧网格 |

## 原理

音节筛选不依赖任何引擎补丁，纯 librime-lua 实现：

1. `lua_translator` 对纯数字输入用「全拼合法音节前缀树」DFS 枚举所有切分，把可选首音节产出为候选（text 留空、拼音放 comment）
2. 点选后经 `select_notifier` 扫描 composition 还原被点中的音节，将 `context.input` 从 `94343` 改写为 `zhe'43`
3. 引擎原生接力：字母按精确拼音、剩余数字继续 T9

完整技术验证（含真实转录与 11 条踩坑）见 [docs/syllable-prototype-report.md](docs/syllable-prototype-report.md)。

## 使用

（待补：打包发布流程）

## 致谢与许可

- 主题基底：[同文风·增强版](https://github.com/SivanLaai/rime-pure) by SivanLaai（MIT License）
- 输入方案基底：[雾凇拼音 rime-ice](https://github.com/iDvel/rime-ice) by iDvel 及贡献者（GPL-3.0）
- 本项目整体以 [GPL-3.0](LICENSE) 发布
