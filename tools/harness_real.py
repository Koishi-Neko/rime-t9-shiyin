# -*- coding: utf-8 -*-
"""真实手机包 t9.schema.yaml 的无头回归 harness

复用 harness.py 的 ctypes 层（小狼毫 rime.dll / librime + librime-lua），在沙箱用户目录里
编译**真实的 rime-ice-t9-phone 包**（真实 rime_ice 词典），对比：

  base  变体：原包原样（移植前基线）
  port  变体：原包 + 本项目移植后的 t9.schema.yaml / lua

用法：
    python harness_real.py all   --variant port      # 部署 + 跑场景（推荐）
    python harness_real.py all   --variant base      # 移植前基线
    python harness_real.py deploy --variant port     # 只编译
    python harness_real.py run    --variant port --mode empty

绝不动 %APPDATA%\\Rime，不跑 WeaselDeployer。沙箱、日志、编译产物全部落在工作目录里
（默认是原型工程旁边：`../rime-lexicon/t9-syllable-prototype/out/realtest/`），
不写进本仓库。路径可用环境变量覆盖：

    T9_REPO        本仓库根目录（默认：本脚本的上一级）
    T9_WORKSPACE   工作目录，放沙箱用户目录/日志/原包副本（默认见上）
    T9_PKG         解压后的手机包目录（默认 $T9_WORKSPACE/pkg/rime-ice-t9-phone-main）
    T9_TRANSCRIPTS 转录输出目录（默认：原型工程的 transcripts/）
"""

from __future__ import annotations

import argparse
import ctypes
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

sys.stdout.reconfigure(encoding="utf-8")

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import harness as H  # noqa: E402  （ctypes / RimeApi / Rime / keysym 全在这一层）

REPO = Path(os.environ.get("T9_REPO", HERE.parent))
PROTOTYPE = REPO.parent / "rime-lexicon" / "t9-syllable-prototype"
ROOT = Path(os.environ.get("T9_WORKSPACE", PROTOTYPE / "out" / "realtest"))
PKG = Path(os.environ.get("T9_PKG", ROOT / "pkg" / "rime-ice-t9-phone-main"))
LOG_DIR = ROOT / "log"
TRANSCRIPT_DIR = Path(os.environ.get("T9_TRANSCRIPTS", PROTOTYPE / "transcripts"))

SCHEMA_ID = "t9"

H.LOG_DIR = LOG_DIR  # Rime.__init__ 用它建日志目录


def sandbox(variant: str) -> Path:
    return ROOT / f"user_{variant}"


def build_sandbox(variant: str, keep_build: bool) -> Path:
    """把真实包拷进沙箱；port 变体再覆盖本项目的 t9.schema.yaml 与 lua。"""
    dst = sandbox(variant)
    build = dst / "build"
    if keep_build and build.exists():
        shutil.rmtree(build)
    if dst.exists():
        shutil.rmtree(dst)
    dst.mkdir(parents=True)
    shutil.copytree(PKG, dst, dirs_exist_ok=True)

    if variant == "port":
        shutil.copy2(REPO / "schema" / "t9.schema.yaml", dst / "t9.schema.yaml")
        for lua in sorted((REPO / "lua").glob("*.lua")):
            shutil.copy2(lua, dst / "lua" / lua.name)
    return dst


def cmd_deploy(variant: str) -> int:
    dst = build_sandbox(variant, keep_build=True)
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    log = LOG_DIR / "t9_debug.log"
    if log.exists():
        log.unlink()
    os.environ["T9_LOG"] = str(log)
    print(f"== 沙箱用户目录：{dst}")
    t0 = time.time()
    r = H.Rime(dst, deploy_mode=True)
    ok = H.bind(r.api, "deploy", ctypes.c_int)()
    print(f"== deploy 返回 {ok}，耗时 {time.time() - t0:.1f}s")
    table = dst / "build" / "rime_ice.table.bin"   # t9 的 translator/dictionary 是 rime_ice，表在 rime_ice.table.bin
    prism = dst / "build" / f"{SCHEMA_ID}.prism.bin"
    for f in (prism, table):
        print(f"== {f.name}: {'%d bytes' % f.stat().st_size if f.exists() else '缺失!'}")
    if not (prism.exists() and table.exists()):
        print("[FAIL] 编译产物缺失，日志尾部：")
        for f in sorted(LOG_DIR.glob("*.log")):
            print(f"--- {f.name} ---")
            print(f.read_text(encoding="utf-8", errors="replace")[-3000:])
        r.close()
        return 2
    r.close()
    return 0


# ---------------------------------------------------------------------------
# 场景
# ---------------------------------------------------------------------------
def hdr(title: str) -> None:
    print()
    print("=" * 78)
    print(title)
    print("=" * 78)


def show_candidates(r: H.Rime, limit: int = 30) -> None:
    cands = r.candidates()
    print(f"   候选 {len(cands)} 条：")
    for i, (t, c) in enumerate(cands[:limit]):
        mark = "*" if t == "" else " "
        print(f"     [{i:2d}]{mark} text={t!r:<12} comment={c!r}")
    return cands


def is_syllable_cand(t: str, c: str) -> bool:
    """音节候选的判定：text 是纯拼音音节，comment 是同一音节（可能带 '剩余数字'）。
    例：text='zhe' comment="zhe'43"（text 模式，真机默认）
        text=''    comment="zhe'43"（t9_syllable_empty_text 空 text 备选模式）
    词典候选的 comment 是带空格的拼读（'zhe ge'）或为空，不会误判。"""
    import re
    pattern = r"^[a-z]+('[0-9]+)?$"
    if t:
        return re.match(pattern, t) is not None and (c == t or c.startswith(t + "'"))
    return re.match(pattern, c) is not None


def apply_mode(r: H.Rime, mode: str) -> None:
    """text（真机验收后的默认渲染模式）| empty（零泄漏备选模式，信息全在 comment）"""
    r.set_option("t9_syllable_empty_text", mode == "empty")


def split_cands(cands) -> tuple[list, list]:
    syl, rest = [], []
    for c in cands:
        (syl if is_syllable_cand(*c) else rest).append(c)
    return syl, rest


def digit_segmentations(digits: str, codes: set[str]) -> list[str]:
    """Python 参考实现：用包里的数字码集合枚举切分（与 lua 侧对照）"""
    out: list[str] = []

    def dfs(pos: int, acc: list[str]):
        if len(out) >= 200 or pos == len(digits):
            if pos == len(digits):
                out.append("'".join(acc))
            return
        for end in range(pos + 1, len(digits) + 1):
            code = digits[pos:end]
            if code in codes:
                dfs(end, acc + [code])

    dfs(0, [])
    return out


def load_package_codes() -> set[str]:
    text = (PKG / "lua" / "t9_default_abbreviation_segmentor.lua").read_text(encoding="utf-8")
    body = text.split("local FULL_PINYIN_CODES = [[", 1)[1].split("]]", 1)[0]
    return set(body.split())


# ---------------------------------------------------------------------------
# 回归场景（base / port 共用；port 额外跑音节链路）
# ---------------------------------------------------------------------------
REGRESSION_INPUTS = [
    ("94343", "这个"),      # zhe ge（移植前实测首候选就是它）
    ("74264", "上"),        # shang / qiang
    ("98", "无"),           # wu / yu / xu / zu
    ("636", "们"),          # men / nen
    ("26426", "拨号"),      # bo hao
    ("48268", "花木"),      # hua mu
]


def scenario_regression(r: H.Rime, transcript: list[str], tag: str) -> None:
    hdr(f"[{tag}] 回归：常见数字串直接出词典候选（普通九宫格输入不受影响）")
    for digits, want in REGRESSION_INPUTS:
        r.clear()
        r.set_input(digits)
        cands = show_candidates(r)
        texts = [t for t, _ in cands]
        hit = any(want in t for t in texts)
        first_dict = next((t for t, c in cands if not is_syllable_cand(t, c)), None)
        print(f"   input={digits} 期望含 {want!r} -> {hit}；首个词典候选 = {first_dict!r}")
        transcript.append(
            f"[{tag}] input={digits} 想要={want} 命中={hit} 首个词典候选={first_dict!r} "
            f"前8候选={texts[:8]}")


def scenario_delimiter(r: H.Rime, transcript: list[str], tag: str) -> None:
    """撇号分隔符探针：zhe'43 能否解析成「这」+ 数字43（delimiter 是否生效）"""
    hdr(f"[{tag}] 撇号分隔符探针（speller/delimiter: \" '\"）")
    for text in ("zhe'43", "zhe43", "zhe'ge", "zhege"):
        r.clear()
        r.set_input(text)
        cands = r.candidates()
        print(f"   input={text!r} -> {len(cands)} 条：{[t for t, _ in cands[:6]]}")
        transcript.append(f"[{tag}] probe input={text!r} -> {len(cands)} 条 {[t for t, _ in cands[:6]]}")


def scenario_word_select(r: H.Rime, transcript: list[str], tag: str) -> None:
    """点选词典候选是否照常上屏 —— fluid_editor 会不会吃掉「点词即上屏」"""
    hdr(f"[{tag}] 点选词典候选是否仍然上屏（editor 回归关键）")
    for digits, word in (("94343", "这个"), ("74264", "上")):
        r.clear()
        r.set_input(digits)
        cands = r.candidates()
        idx = next((i for i, (t, _) in enumerate(cands) if t == word), None)
        if idx is None:
            print(f"   {digits}: 候选里没有 {word!r}，跳过")
            transcript.append(f"[{tag}] {digits} 没有 {word!r}，跳过")
            continue
        ok = r.select(idx)
        comm = r.take_commit()
        print(f"   {digits} 点选 #{idx}({word}) select={ok} commit={comm!r} input={r.input()!r}")
        transcript.append(f"[{tag}] {digits} 点选词典候选 {word} -> commit={comm!r} input={r.input()!r}")


def scenario_space(r: H.Rime, transcript: list[str], tag: str) -> None:
    """空格键行为：高亮的是音节候选时=锁定音节；高亮的是词候选时=上屏"""
    hdr(f"[{tag}] 空格键行为")
    r.clear()
    r.set_input("94343")
    cands = r.candidates()
    print(f"   空格前 input={r.input()!r} 首候选={cands[0] if cands else None}")
    consumed = r.key("space")
    comm = r.take_commit()
    after = r.input()
    print(f"   space#1: consumed={consumed} input={after!r} commit={comm!r} preedit={r.preedit()!r}")
    transcript.append(
        f"[{tag}] 94343 + space#1 -> consumed={consumed} input={after!r} commit={comm!r} "
        f"preedit={r.preedit()!r}")
    # 再接一次空格：此时高亮的是词候选，应当直接上屏（证明空格流程没被破坏）
    consumed2 = r.key("space")
    comm2 = r.take_commit()
    print(f"   space#2: consumed={consumed2} input={r.input()!r} commit={comm2!r}")
    transcript.append(f"[{tag}] space#2 -> consumed={consumed2} commit={comm2!r} input={r.input()!r}")
    r.clear()
    r.set_input("94343")
    consumed = r.key("Return")
    comm = r.take_commit()
    print(f"   Return: consumed={consumed} input={r.input()!r} commit={comm!r}")
    transcript.append(f"[{tag}] 94343 + Return -> consumed={consumed} commit={comm!r}")


def scenario_syllable_flow(r: H.Rime, transcript: list[str], mode: str) -> None:
    hdr(f"[port] 音节候选：94343 → 点选 zhe → input=zhe'43 → 词典候选接力（mode={mode}）")
    r.clear()
    r.set_input("94343")
    print(f"   input={r.input()!r}  preedit={r.preedit()!r}")
    cands = show_candidates(r)
    syl, rest = split_cands(cands)
    print(f"\n   >> 音节候选 {len(syl)} 条：{[(c[1].split(' |')[0], c[0]) for c in syl]}")
    print(f"   >> 词典候选 {len(rest)} 条：{[c[0] for c in rest[:8]]}")
    transcript.append(
        f"[port:{mode}] input=94343 音节候选({len(syl)})={[(c[1].split(' |')[0], c[0]) for c in syl]} "
        f"词典候选({len(rest)})={[c[0] for c in rest[:8]]}")

    idx = next((i for i, (t, c) in enumerate(cands)
                if is_syllable_cand(t, c) and c.startswith("zhe'")), None)
    if idx is None:
        print("   [FAIL] 找不到 zhe 音节候选")
        transcript.append(f"[port:{mode}] FAIL: 找不到 zhe 音节候选")
        return
    print(f"\n   点选 #{idx}（zhe）…")
    ok = r.select(idx)
    after = r.input()
    comm = r.take_commit()
    print(f"   select()={ok}  input={after!r}  preedit={r.preedit()!r}  commit={comm!r}")
    cands2 = show_candidates(r)
    texts2 = [t for t, _ in cands2]
    relay = any("这个" == t for t in texts2)
    rewrite_ok = after == "zhe'43"
    print(f"\n   >> 改写成功? {rewrite_ok}   接力出「这个」? {relay}   无泄漏? {comm == ''}")
    transcript.append(
        f"[port:{mode}] 94343 --select(zhe)--> input={after!r} commit={comm!r} "
        f"rewrite_ok={rewrite_ok} relay_ok={relay} leak={comm!r}")
    # 接力之后再点词候选，验证「音节锁定 → 选词上屏」整条链路
    widx = next((i for i, (t, _) in enumerate(cands2) if t == "这个"), None)
    if widx is not None:
        r.select(widx)
        comm2 = r.take_commit()
        print(f"   点选 #{widx}（这个）-> commit={comm2!r}")
        transcript.append(f"[port:{mode}] 接力后点选 这个 -> commit={comm2!r}")


def scenario_remedy(r: H.Rime, transcript: list[str]) -> None:
    """补救路径：关掉 filter 的 partial 处理（整段候选 + express_editor 自动提交），
    靠 commit_notifier 暂存的输入继续改写。"""
    hdr("[port] 补救路径：t9_syllable_no_partial 打开后点选音节候选")
    r.set_option("t9_syllable_no_partial", True)
    r.clear()
    r.set_input("94343")
    cands = r.candidates()
    idx = next((i for i, (t, c) in enumerate(cands)
                if is_syllable_cand(t, c) and c.startswith("zhe'")), None)
    if idx is None:
        print("   [FAIL] 找不到 zhe 音节候选")
        transcript.append("[port] 补救路径 FAIL: 找不到 zhe 音节候选")
    else:
        r.select(idx)
        comm = r.take_commit()
        after = r.input()
        print(f"   点选 #{idx}(zhe) -> commit={comm!r} input={after!r} preedit={r.preedit()!r}")
        transcript.append(f"[port] 补救路径 点选 zhe -> commit={comm!r} input={after!r}")
    r.set_option("t9_syllable_no_partial", False)


def scenario_leak(r: H.Rime, transcript: list[str], tag: str, mode: str) -> None:
    """引擎层提交泄漏排查：纯数字输入过程中、以及点选音节候选时，commit 是否始终为空；
    同时记录 commit_text_preview（宿主若把它当「待上屏文本」同步进文本框，就会看到它）。"""
    hdr(f"[{tag}] 提交泄漏排查：逐键输入 + 点选音节（mode={mode}）")
    r.clear()
    leaks = []
    for ch in "94343":
        r.key(ch)
        comm = r.take_commit()
        if comm:
            leaks.append((ch, comm))
        print(f"   敲 {ch}: input={r.input()!r} commit={comm!r} preview={r.preview()!r}")
    transcript.append(
        f"[{tag}:{mode}] 逐键敲 94343 每键 commit 非空次数={len(leaks)}"
        f"（期望 0）；末态 preview={r.preview()!r}")

    r.clear()
    r.set_input("94343")
    cands = r.candidates()
    print(f"   set_input: input={r.input()!r} commit={r.take_commit()!r} preview={r.preview()!r}")
    idx = next((i for i, (t, c) in enumerate(cands) if is_syllable_cand(t, c) and c.startswith("zhe'")), None)
    if idx is None:
        print("   [SKIP] 没有 zhe 音节候选")
        return
    r.select(idx)
    comm = r.take_commit()
    print(f"   点选 #{idx}(zhe): input={r.input()!r} commit={comm!r} preview={r.preview()!r} "
          f"preedit={r.preedit()!r}")
    transcript.append(
        f"[{tag}:{mode}] 点选音节候选 -> commit={comm!r} input={r.input()!r} "
        f"preview={r.preview()!r} preedit={r.preedit()!r}")

    # 诊断：跳过改写，观察「partial 选择已发生、但 input 还没被改写」这一瞬间的引擎状态。
    # 这是真机「文本框里出现 343」最可能的来源：该状态下 commit_text_preview == 尾部数字。
    r.set_option("t9_syllable_no_rewrite", True)
    r.clear()
    r.set_input("94343")
    r.select(idx)
    comm = r.take_commit()
    print(f"   [诊断] 不做改写时点选 #{idx}: input={r.input()!r} commit={comm!r} "
          f"preview={r.preview()!r} preedit={r.preedit()!r}")
    transcript.append(
        f"[{tag}:{mode}] 诊断(跳过改写) 点选音节候选 -> commit={comm!r} input={r.input()!r} "
        f"preview={r.preview()!r} preedit={r.preedit()!r}")
    r.set_option("t9_syllable_no_rewrite", False)


GREEK_VARIANTS = "ξΞπΠχΧμΜνΝ"   # opencc/others.txt 里 5 个音节的希腊字母映射


def scenario_emoji_variants(r: H.Rime, transcript: list[str], tag: str) -> None:
    """音节候选的 text 非空后，会不会被 opencc emoji/others 词典二次加工出变体候选。
    对照点：94343/74264 的首屏是音节候选（base 变体没有音节候选，可对照）；
    244/68 两个输入本来就没有音节候选，它们的 χ/Χ、μ/Μ/ν/Ν 来自词典里 text 就是拼音的
    英文类词条（melt_eng 的 chi/mu/nu），base 与 port 应当一模一样 —— 属于原包既有行为。"""
    hdr(f"[{tag}] 音节候选是否派生 emoji/symbol 变体（xi→ξ/Ξ、pi→π/Π…）")
    for digits, what in (("94343", "首屏是音节候选"), ("74264", "首屏是音节候选"),
                         ("244", "无音节候选（对照）"), ("68", "无音节候选（对照）")):
        r.clear()
        r.set_input(digits)
        cands = r.candidates()
        texts = [t for t, _ in cands]
        head = texts[:10]
        variants = [t for t in texts if t and t[0] in GREEK_VARIANTS]
        head_variants = [t for t in head if t and t[0] in GREEK_VARIANTS]
        print(f"   input={digits}（{what}）共 {len(texts)} 条")
        print(f"      前 10 候选={head}")
        print(f"      首屏希腊字母={head_variants}  全表希腊字母={variants}")
        transcript.append(
            f"[{tag}] input={digits}({what}) 前10候选={head} 首屏希腊字母={head_variants} "
            f"全表希腊字母={variants}")


def find_cand(cands, comment_prefix: str) -> int | None:
    """按 comment 前缀找音节候选（comment 就是这个候选定下来的写法：zhe'43 / ge）。"""
    return next((i for i, (t, c) in enumerate(cands)
                 if is_syllable_cand(t, c) and c.startswith(comment_prefix)), None)


def scenario_continuous(r: H.Rime, transcript: list[str], mode: str) -> None:
    """连续逐字选音节：点完一个音节后，剩余数字继续出音节候选，直到全部定完再出词候选。"""
    hdr(f"[port] 连续逐字选音节（mode={mode}）")
    # （输入, [(点选的音节写法, 期望改写后的 input), ...], 最后点选上屏的词)
    plans = [
        ("94343", [("zhe'43", "zhe'43"), ("ge", "zhe'ge")], "这个"),
        ("74264", [("pia'64", "pia'64"), ("mi", "pia'mi")], None),
        ("944343", [("yi'4343", "yi'4343"), ("ge'43", "yi'ge'43"), ("ge", "yi'ge'ge")], None),
    ]
    for digits, steps, final_word in plans:
        print(f"\n-- {digits} 连续选 {len(steps)} 步 --")
        r.clear()
        r.set_input(digits)
        ok_all = True
        line = [f"[port:{mode}] {digits}"]
        for syl_comment, want_input in steps:
            cands = r.candidates()
            idx = find_cand(cands, syl_comment)
            if idx is None:
                print(f"   [FAIL] 输入 {r.input()!r} 时找不到候选 comment={syl_comment!r}"
                      f"（前 8={[(t, c) for t, c in cands[:8]]}）")
                line.append(f"FAIL(找不到 {syl_comment})")
                ok_all = False
                break
            n_syl, n_dict = len(split_cands(cands)[0]), len(split_cands(cands)[1])
            r.select(idx)
            comm = r.take_commit()
            after = r.input()
            step_ok = (after == want_input and comm == "")
            ok_all = ok_all and step_ok
            print(f"   点 #{idx}({syl_comment})：候选 {n_syl} 音节/{n_dict} 词典 → "
                  f"input={after!r} commit={comm!r} preview={r.preview()!r} step_ok={step_ok}")
            line.append(f"{syl_comment}→{after!r}(commit={comm!r})")
        else:
            # 全部音节定完之后：候选里应出现词候选，点它上屏
            if final_word is not None:
                cands = r.candidates()
                widx = next((i for i, (t, _) in enumerate(cands) if t == final_word), None)
                if widx is None:
                    print(f"   [FAIL] {r.input()!r} 的候选里没有 {final_word!r}"
                          f"（前 6={[t for t, _ in cands[:6]]}）")
                    line.append(f"FAIL(无 {final_word})")
                    ok_all = False
                else:
                    r.select(widx)
                    comm = r.take_commit()
                    print(f"   点词 #{widx}({final_word}) -> commit={comm!r}（应为 {final_word}）")
                    line.append(f"点词{final_word}→commit={comm!r}")
                    ok_all = ok_all and comm == final_word
        transcript.append(" ".join(line) + f" 全链OK={ok_all}")

    # 连续选节的中间态：候选里音节候选打头、词典候选跟在后面（对比 base 的词典候选顺序）
    for text in ("zhe'43", "zhe'ge", "yi'ge'43"):
        r.clear()
        r.set_input(text)
        cands = r.candidates()
        syl, rest = split_cands(cands)
        print(f"\n  中间态 {text!r}：音节候选 {[c[1] for c in syl]}，词典候选前 5={[t for t, _ in rest[:5]]}")
        transcript.append(
            f"[port:{mode}] 中间态 {text!r} 音节候选={[c[1] for c in syl]} "
            f"词典候选前5={[t for t, _ in rest[:5]]}")


def scenario_final_syllable(r: H.Rime, transcript: list[str], mode: str) -> None:
    """末音节（音节正好吃掉整段输入，如 436→gen、343→die）点选也不能有提交。
    这是 filter 的「顶到输入末尾再缩一位」规则要保证的事。"""
    hdr(f"[port] 末音节点选零提交（mode={mode}）")
    for digits, syl, want in (("436", "gen", "gen"), ("343", "die", "die"),
                              ("943", "zhe", "zhe")):
        r.clear()
        r.set_input(digits)
        cands = r.candidates()
        idx = find_cand(cands, syl)
        if idx is None:
            print(f"   {digits}: 没有 {syl} 候选，跳过")
            transcript.append(f"[port:{mode}] {digits} 没有 {syl} 候选，跳过")
            continue
        r.select(idx)
        comm = r.take_commit()
        after = r.input()
        ok = comm == "" and after == want
        print(f"   {digits} 点末音节 #{idx}({syl}) -> commit={comm!r} input={after!r} ok={ok}")
        transcript.append(f"[port:{mode}] {digits} 点末音节 {syl} -> commit={comm!r} "
                          f"input={after!r} ok={ok}")


def scenario_single_split(r: H.Rime, transcript: list[str]) -> None:
    hdr("[port] 切分门槛：整段单音节不出（98/436）；唯一切分但有段边界且首音节歧义则出（9378/9434）")
    codes = load_package_codes()
    for digits in ("98", "94", "436", "9378", "9434", "2246"):
        segs = digit_segmentations(digits, codes)
        r.clear()
        r.set_input(digits)
        cands = r.candidates()
        syl, rest = split_cands(cands)
        print(f"\n   input={digits}：切分 {len(segs)} 种 {segs[:6]}"
              f"{' ...' if len(segs) > 6 else ''}")
        print(f"     -> 音节候选 {len(syl)} 条 / 词典候选 {len(rest)} 条；前5候选={[t for t, _ in cands[:5]]}")
        transcript.append(
            f"[port] input={digits} 切分数={len(segs)} 音节候选={len(syl)} "
            f"词典候选={len(rest)} 前5候选={[t for t, _ in cands[:5]]}")


def scenario_processor(r: H.Rime, transcript: list[str], tag: str) -> None:
    hdr(f"[{tag}] 兜底：Tab 循环切分在真实 schema 下工作")
    r.clear()
    r.set_input("94343")
    print(f"   起始 input={r.input()!r}")
    seen = []
    for i in range(8):
        if not r.key("Tab"):
            print(f"   Tab 第 {i + 1} 次未被消费（process_key 返回 0）")
            break
        seen.append(r.input())
        print(f"   Tab #{i + 1} -> input={r.input()!r}  preedit={r.preedit()!r}")
    transcript.append(f"[{tag}] Tab 循环结果：{seen}")
    # Tab 之后必须还能正常继续输入（不影响普通键）
    r.clear()
    for ch in "94343":
        r.key(ch)
    print(f"   逐键敲 94343 -> input={r.input()!r}")
    transcript.append(f"[{tag}] 逐键敲 94343 -> input={r.input()!r} 候选={[t for t, _ in r.candidates()[:6]]}")
    # 续段的 Tab 循环：已经确认了 zhe，Tab 应当接着切剩余数字 43
    r.clear()
    r.set_input("zhe'43")
    seen2 = []
    for i in range(4):
        if not r.key("Tab"):
            print(f"   （续段）Tab 第 {i + 1} 次未被消费")
            break
        seen2.append(r.input())
        print(f"   （续段）Tab #{i + 1} -> input={r.input()!r}")
    transcript.append(f"[{tag}] 续段 zhe'43 Tab 循环结果：{seen2}")


def cmd_run(variant: str, mode: str) -> int:
    dst = sandbox(variant)
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    log = LOG_DIR / "t9_debug.log"
    if log.exists():
        log.unlink()
    os.environ["T9_LOG"] = str(log)
    os.environ["T9_CORE_LOG"] = str(log)

    r = H.Rime(dst)
    print(f"== librime {r.version}，当前方案 = {r.schema()}")
    if r.schema() != SCHEMA_ID:
        r.select_schema(SCHEMA_ID)
        print(f"== 切换到方案 = {r.schema()}")

    transcript: list[str] = [f"# variant={variant} mode={mode} librime={r.version}"]
    try:
        if variant == "port":
            apply_mode(r, mode)
        # 先跑「只看不改」的场景（它们的词典候选列表必须是干净的初始状态），
        # 会提交候选的场景（点词、空格）放最后，避免用户词典学习影响前面的读数。
        scenario_regression(r, transcript, variant)
        scenario_delimiter(r, transcript, variant)
        if variant == "port":
            scenario_single_split(r, transcript)
            scenario_final_syllable(r, transcript, mode)
        scenario_emoji_variants(r, transcript, variant)
        scenario_leak(r, transcript, variant, mode)
        if variant == "port":
            scenario_continuous(r, transcript, mode)
            scenario_syllable_flow(r, transcript, mode)
            scenario_remedy(r, transcript)
        scenario_word_select(r, transcript, variant)
        scenario_space(r, transcript, variant)
        scenario_processor(r, transcript, variant)
    finally:
        r.close()

    print()
    print("=" * 78)
    print("LUA 内部日志（尾部）")
    print("=" * 78)
    if log.exists():
        lines = log.read_text(encoding="utf-8", errors="replace").splitlines()
        for line in lines[-60:]:
            print("   " + line)

    transcript.append(f"# lua 日志：{log}")
    TRANSCRIPT_DIR.mkdir(parents=True, exist_ok=True)
    if variant == "port" and mode == "text":
        name = "run_realpackage.txt"          # 真机验收后的默认渲染模式
    elif variant == "port":
        name = f"run_realpackage_{mode}.txt"
    else:
        name = "run_realpackage_base.txt"
    out = TRANSCRIPT_DIR / name
    out.write_text("\n".join(transcript) + "\n", encoding="utf-8")
    print(f"\n== 场景摘要已写入 {out}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["all", "deploy", "run"], nargs="?", default="all")
    ap.add_argument("--variant", choices=["base", "port"], default="port")
    ap.add_argument("--mode", choices=["text", "empty"], default="text")
    args = ap.parse_args()

    if args.cmd == "deploy":
        return cmd_deploy(args.variant)
    if args.cmd == "run":
        return cmd_run(args.variant, args.mode)

    rc = cmd_deploy(args.variant)
    if rc:
        return rc
    print("\n" + "#" * 78)
    print("# 另起进程跑场景（deployer 与 engine 分进程）")
    print("#" * 78)
    return subprocess.call([sys.executable, str(Path(__file__).resolve()), "run",
                            "--variant", args.variant, "--mode", args.mode])


if __name__ == "__main__":
    raise SystemExit(main())
