# -*- coding: utf-8 -*-
"""T9 音节切分原型 —— librime 无头测试 harness

用 python ctypes 直接调小狼毫的 rime.dll（librime + librime-lua），在沙箱用户目录里
编译一个最小方案 t9prot，逐条验证：

  M1 切分枚举       纯 Lua DFS，枚举所有合法全拼切分（并与 Python 参考实现对照）
  M2 音节候选       lua_translator 把每个可选“首音节”输出成候选
  M3 点选拦截       选中音节候选后不改上屏、而是把 context.input 改写成精确拼音
  M4 混合接力       input 变成 zhe'43 后，字母部分按精确拼音、数字部分继续 T9

用法：
    python harness.py all                 # 部署 + 跑全部场景（推荐）
    python harness.py deploy              # 只重建沙箱并编译方案
    python harness.py run                 # 只跑场景（假定已 deploy）
    python harness.py run --mode empty    # 用空串候选 text 模式跑 M3
    python harness.py run --mode marker   # 用标记候选 text 模式跑 M3

绝不动真实用户目录 %APPDATA%\\Rime，也不跑 WeaselDeployer。
"""

from __future__ import annotations

import argparse
import ctypes
import os
import shutil
import subprocess
import sys
from pathlib import Path

sys.stdout.reconfigure(encoding="utf-8")

HERE = Path(__file__).resolve().parent
SRC = HERE / "rime"
USER_DIR = HERE / "out" / "user"
LOG_DIR = HERE / "out" / "log"
TRANSCRIPT = HERE / "transcripts"

WEASEL_DIR = Path(r"C:\Program Files\Rime\weasel-0.17.4")
RIME_DLL = WEASEL_DIR / "rime.dll"
SHARED_DATA = WEASEL_DIR / "data"

# ---------------------------------------------------------------------------
# RimeApi / 结构体（严格照 librime 1.13.x src/rime_api.h 字段顺序）
# ---------------------------------------------------------------------------
API_FIELDS = [
    "setup", "set_notification_handler", "initialize", "finalize",
    "start_maintenance", "is_maintenance_mode", "join_maintenance_thread",
    "deployer_initialize", "prebuild", "deploy", "deploy_schema",
    "deploy_config_file", "sync_user_data",
    "create_session", "find_session", "destroy_session",
    "cleanup_stale_sessions", "cleanup_all_sessions",
    "process_key", "commit_composition", "clear_composition",
    "get_commit", "free_commit", "get_context", "free_context",
    "get_status", "free_status",
    "set_option", "get_option", "set_property", "get_property",
    "get_schema_list", "free_schema_list", "get_current_schema", "select_schema",
    "schema_open", "config_open", "config_close", "config_get_bool",
    "config_get_int", "config_get_double", "config_get_string",
    "config_get_cstring", "config_update_signature", "config_begin_map",
    "config_next", "config_end", "simulate_key_sequence",
    "register_module", "find_module", "run_task",
    "get_shared_data_dir", "get_user_data_dir", "get_sync_dir",
    "get_user_id", "get_user_data_sync_dir",
    "config_init", "config_load_string", "config_set_bool", "config_set_int",
    "config_set_double", "config_set_string", "config_get_item", "config_set_item",
    "config_clear", "config_create_list", "config_create_map", "config_list_size",
    "config_begin_list",
    "get_input", "get_caret_pos", "select_candidate", "get_version",
    "set_caret_pos", "select_candidate_on_current_page",
    "candidate_list_begin", "candidate_list_next", "candidate_list_end",
    "user_config_open", "candidate_list_from_index",
    "get_prebuilt_data_dir", "get_staging_dir",
    "commit_proto", "context_proto", "status_proto",
    "get_state_label", "delete_candidate", "delete_candidate_on_current_page",
    "get_state_label_abbreviated", "set_input",
    "get_shared_data_dir_s", "get_user_data_dir_s", "get_prebuilt_data_dir_s",
    "get_staging_dir_s", "get_sync_dir_s",
    "highlight_candidate", "highlight_candidate_on_current_page", "change_page",
]


class RimeApi(ctypes.Structure):
    _fields_ = [("data_size", ctypes.c_int)] + [(n, ctypes.c_void_p) for n in API_FIELDS]


class RimeTraits(ctypes.Structure):
    _fields_ = [
        ("data_size", ctypes.c_int),
        ("shared_data_dir", ctypes.c_char_p),
        ("user_data_dir", ctypes.c_char_p),
        ("distribution_name", ctypes.c_char_p),
        ("distribution_code_name", ctypes.c_char_p),
        ("distribution_version", ctypes.c_char_p),
        ("app_name", ctypes.c_char_p),
        ("modules", ctypes.c_void_p),
        ("min_log_level", ctypes.c_int),
        ("log_dir", ctypes.c_char_p),
        ("prebuilt_data_dir", ctypes.c_char_p),
        ("staging_dir", ctypes.c_char_p),
    ]


class RimeComposition(ctypes.Structure):
    _fields_ = [("length", ctypes.c_int), ("cursor_pos", ctypes.c_int),
                ("sel_start", ctypes.c_int), ("sel_end", ctypes.c_int),
                ("preedit", ctypes.c_char_p)]


class RimeCandidate(ctypes.Structure):
    _fields_ = [("text", ctypes.c_char_p), ("comment", ctypes.c_char_p),
                ("reserved", ctypes.c_void_p)]


class RimeMenu(ctypes.Structure):
    _fields_ = [("page_size", ctypes.c_int), ("page_no", ctypes.c_int),
                ("is_last_page", ctypes.c_int), ("highlighted_candidate_index", ctypes.c_int),
                ("num_candidates", ctypes.c_int), ("candidates", ctypes.POINTER(RimeCandidate)),
                ("select_keys", ctypes.c_char_p)]


class RimeContext(ctypes.Structure):
    _fields_ = [("data_size", ctypes.c_int), ("composition", RimeComposition),
                ("menu", RimeMenu), ("commit_text_preview", ctypes.c_char_p),
                ("select_labels", ctypes.c_void_p)]


class RimeCommit(ctypes.Structure):
    _fields_ = [("data_size", ctypes.c_int), ("text", ctypes.c_char_p)]


class RimeCandidateListIterator(ctypes.Structure):
    _fields_ = [("ptr", ctypes.c_void_p), ("index", ctypes.c_int), ("candidate", RimeCandidate)]


def struct_init(obj) -> None:
    obj.data_size = ctypes.sizeof(type(obj)) - ctypes.sizeof(ctypes.c_int)


def bind(api, name, restype, *argtypes):
    return ctypes.CFUNCTYPE(restype, *argtypes)(getattr(api, name))


# X11 keysym（librime 用 keysym 编码）
KEYSYM = {
    "Tab": 0xFF09, "F2": 0xFFBF, "Return": 0xFF0D, "space": 0x20, "Escape": 0xFF1B,
}
for _i, _c in enumerate("0123456789"):
    KEYSYM[_c] = ord(_c)
for _c in "abcdefghijklmnopqrstuvwxyz":
    KEYSYM[_c] = ord(_c)


class Rime:
    def __init__(self, user_dir: Path, deploy_mode: bool = False):
        os.add_dll_directory(str(WEASEL_DIR))
        self.lib = ctypes.CDLL(str(RIME_DLL))
        self.lib.rime_get_api.restype = ctypes.POINTER(RimeApi)
        api = self.lib.rime_get_api().contents
        expected = ctypes.sizeof(RimeApi) - ctypes.sizeof(ctypes.c_int)
        if api.data_size != expected:
            raise SystemExit(f"[FATAL] RimeApi 结构不匹配：库 {api.data_size} vs 脚本 {expected}")
        self.api = api
        self.version = bind(api, "get_version", ctypes.c_char_p)().decode()

        traits = RimeTraits()
        struct_init(traits)
        traits.shared_data_dir = str(SHARED_DATA).encode()
        traits.user_data_dir = str(user_dir).encode()
        traits.distribution_name = "小狼毫".encode()
        traits.distribution_code_name = b"Weasel"
        traits.distribution_version = b"0.17.4"
        traits.app_name = b"rime.t9proto"
        LOG_DIR.mkdir(parents=True, exist_ok=True)
        traits.log_dir = str(LOG_DIR).encode()

        self.deploy_mode = deploy_mode
        if deploy_mode:
            bind(api, "setup", None, ctypes.POINTER(RimeTraits))(ctypes.byref(traits))
            bind(api, "deployer_initialize", None, ctypes.POINTER(RimeTraits))(ctypes.byref(traits))
            self.sid = 0
        else:
            bind(api, "setup", None, ctypes.POINTER(RimeTraits))(ctypes.byref(traits))
            bind(api, "initialize", None, ctypes.POINTER(RimeTraits))(ctypes.byref(traits))
            self.sid = bind(api, "create_session", ctypes.c_size_t)()
            if not self.sid:
                raise SystemExit("[FATAL] create_session 失败")

    # -- 会话状态 -----------------------------------------------------------
    def input(self) -> str:
        r = bind(self.api, "get_input", ctypes.c_char_p, ctypes.c_size_t)(self.sid)
        return r.decode("utf-8") if r else ""

    def schema(self) -> str:
        buf = ctypes.create_string_buffer(128)
        bind(self.api, "get_current_schema", ctypes.c_int, ctypes.c_size_t,
             ctypes.c_char_p, ctypes.c_size_t)(self.sid, buf, 128)
        return buf.value.decode()

    def select_schema(self, sid_: str) -> None:
        bind(self.api, "select_schema", ctypes.c_int, ctypes.c_size_t, ctypes.c_char_p)(
            self.sid, sid_.encode())

    def set_input(self, text: str) -> None:
        bind(self.api, "set_input", ctypes.c_int, ctypes.c_size_t, ctypes.c_char_p)(
            self.sid, text.encode())

    def clear(self) -> None:
        bind(self.api, "clear_composition", None, ctypes.c_size_t)(self.sid)

    def set_option(self, name: str, value: bool) -> None:
        bind(self.api, "set_option", None, ctypes.c_size_t, ctypes.c_char_p, ctypes.c_int)(
            self.sid, name.encode(), 1 if value else 0)

    def key(self, name: str) -> bool:
        code = KEYSYM[name]
        return bool(bind(self.api, "process_key", ctypes.c_int, ctypes.c_size_t,
                         ctypes.c_int, ctypes.c_int)(self.sid, code, 0))

    def type_string(self, s: str) -> None:
        for ch in s:
            if ch in KEYSYM:
                self.key(ch)
            else:
                raise ValueError(f"无法发送字符 {ch!r}")

    def candidates(self) -> list[tuple[str, str]]:
        out: list[tuple[str, str]] = []
        it = RimeCandidateListIterator()
        cb = bind(self.api, "candidate_list_begin", ctypes.c_int, ctypes.c_size_t,
                  ctypes.POINTER(RimeCandidateListIterator))
        nx = bind(self.api, "candidate_list_next", ctypes.c_int,
                  ctypes.POINTER(RimeCandidateListIterator))
        en = bind(self.api, "candidate_list_end", None, ctypes.POINTER(RimeCandidateListIterator))
        if cb(self.sid, ctypes.byref(it)):
            # 注意：candidate_list_begin 只做 memset，不取首个候选；
            # 必须先 next() 再读 it.candidate，否则会把零值结构体当成一个空候选记进去（下标整体错位）。
            while nx(ctypes.byref(it)):
                c = it.candidate
                out.append((c.text.decode("utf-8", "replace") if c.text else "",
                            c.comment.decode("utf-8", "replace") if c.comment else ""))
            en(ctypes.byref(it))
        return out

    def preedit(self) -> str:
        ctx = RimeContext()
        struct_init(ctx)
        r = bind(self.api, "get_context", ctypes.c_int, ctypes.c_size_t,
                 ctypes.POINTER(RimeContext))(self.sid, ctypes.byref(ctx))
        if not r:
            return ""
        p = ctx.composition.preedit.decode("utf-8", "replace") if ctx.composition.preedit else ""
        bind(self.api, "free_context", ctypes.c_int, ctypes.POINTER(RimeContext))(ctypes.byref(ctx))
        return p

    def preview(self) -> str:
        ctx = RimeContext()
        struct_init(ctx)
        r = bind(self.api, "get_context", ctypes.c_int, ctypes.c_size_t,
                 ctypes.POINTER(RimeContext))(self.sid, ctypes.byref(ctx))
        if not r:
            return ""
        p = ctx.commit_text_preview.decode("utf-8", "replace") if ctx.commit_text_preview else ""
        bind(self.api, "free_context", ctypes.c_int, ctypes.POINTER(RimeContext))(ctypes.byref(ctx))
        return p

    def select(self, index: int) -> bool:
        return bool(bind(self.api, "select_candidate_on_current_page", ctypes.c_int,
                         ctypes.c_size_t, ctypes.c_int)(self.sid, index))

    def select_global(self, index: int) -> bool:
        return bool(bind(self.api, "select_candidate", ctypes.c_int,
                         ctypes.c_size_t, ctypes.c_int)(self.sid, index))

    def take_commit(self) -> str:
        c = RimeCommit()
        struct_init(c)
        r = bind(self.api, "get_commit", ctypes.c_int, ctypes.c_size_t,
                 ctypes.POINTER(RimeCommit))(self.sid, ctypes.byref(c))
        if not r:
            return ""
        t = c.text.decode("utf-8", "replace") if c.text else ""
        bind(self.api, "free_commit", ctypes.c_int, ctypes.POINTER(RimeCommit))(ctypes.byref(c))
        return t

    def close(self) -> None:
        if self.deploy_mode:
            return
        bind(self.api, "destroy_session", ctypes.c_int, ctypes.c_size_t)(self.sid)
        bind(self.api, "finalize", None)()


# ---------------------------------------------------------------------------
# 部署
# ---------------------------------------------------------------------------
def build_user_dir() -> None:
    if USER_DIR.exists():
        shutil.rmtree(USER_DIR)
    USER_DIR.mkdir(parents=True)
    sync_sources()


def sync_sources() -> None:
    """把源码 rime/ 同步进用户目录，但保留 build/（已编译产物）。"""
    USER_DIR.mkdir(parents=True, exist_ok=True)
    for item in SRC.iterdir():
        dst = USER_DIR / item.name
        if item.is_dir():
            if dst.exists():
                shutil.rmtree(dst)
            shutil.copytree(item, dst)
        else:
            shutil.copy2(item, dst)


def cmd_deploy() -> int:
    build_user_dir()
    log = LOG_DIR / "t9_debug.log"
    if log.exists():
        log.unlink()
    os.environ["T9_LOG"] = str(log)
    print(f"== 沙箱用户目录：{USER_DIR}")
    r = Rime(USER_DIR, deploy_mode=True)
    ok = bind(r.api, "deploy", ctypes.c_int)()
    print(f"== deploy 返回 {ok}")
    table = USER_DIR / "build" / "t9prot.table.bin"
    if not table.exists():
        print("[FAIL] 编译后没有 build/t9prot.table.bin")
        for f in LOG_DIR.glob("*.log"):
            print(f"--- {f.name} ---")
            print(f.read_text(encoding="utf-8", errors="replace")[-2000:])
        return 2
    print(f"== build/t9prot.table.bin = {table.stat().st_size} bytes")
    r.close()
    return 0


# ---------------------------------------------------------------------------
# Python 参考枚举（用于对照 Lua 的 DFS 结果，独立实现）
# ---------------------------------------------------------------------------
DIGIT = {**{c: 2 for c in "abc"}, **{c: 3 for c in "def"}, **{c: 4 for c in "ghi"},
         **{c: 5 for c in "jkl"}, **{c: 6 for c in "mno"}, **{c: 7 for c in "pqrs"},
         **{c: 8 for c in "tuv"}, **{c: 9 for c in "wxyz"}}


def load_syllables() -> list[str]:
    text = (SRC / "lua" / "t9_core.lua").read_text(encoding="utf-8")
    body = text.split("local SYLLABLES = [[", 1)[1].split("]]", 1)[0]
    return body.split()


def py_enumerate(digits: str, syllables: list[str]) -> list[str]:
    by_digits: dict[str, list[str]] = {}
    for s in syllables:
        by_digits.setdefault("".join(str(DIGIT[c]) for c in s), []).append(s)
    results: list[str] = []

    def dfs(pos: int, acc: list[str]):
        if len(results) >= 200:
            return
        if pos == len(digits):
            results.append("'".join(acc))
            return
        for end in range(pos + 1, len(digits) + 1):
            key = digits[pos:end]
            if key in by_digits:
                for s in by_digits[key]:
                    dfs(end, acc + [s])

    dfs(0, [])
    return results


# ---------------------------------------------------------------------------
# 场景
# ---------------------------------------------------------------------------
def hdr(title: str) -> None:
    print()
    print("=" * 78)
    print(title)
    print("=" * 78)


def show_candidates(r: Rime, limit: int = 30) -> None:
    cands = r.candidates()
    print(f"   候选 {len(cands)} 条：")
    for i, (t, c) in enumerate(cands[:limit]):
        mark = "*" if t == "" else " "
        print(f"     [{i:2d}]{mark} text={t!r:<14} comment={c!r}")


def scenario_enumerate(r: Rime, transcript: list[str]) -> None:
    hdr("M1/M2 切分枚举 + 音节候选（lua_translator）")
    syllables = load_syllables()
    for digits in ("94", "9434", "94343"):
        print(f"\n-- 输入 {digits} --")
        r.clear()
        r.set_input(digits)
        print(f"   context.input = {r.input()!r}")
        print(f"   preedit       = {r.preedit()!r}")
        show_candidates(r)
        ref = py_enumerate(digits, syllables)
        print(f"   [Python 参考] 共 {len(ref)} 种合法切分：{'; '.join(ref[:12])}"
              + (" ..." if len(ref) > 12 else ""))
        transcript.append(f"input={digits} -> {len(ref)} segmentations: {'; '.join(ref)}")


def find_syllable_cand(cands: list[tuple[str, str]], syllable: str) -> int | None:
    """在候选里找到 text/comment 对应某精确音节的 t9_syllable 候选（返回全局下标）"""
    for i, (t, c) in enumerate(cands):
        if t == syllable:
            return i
        if t in ("",) and c.startswith(syllable):
            return i
        if t == f"\x01{syllable}\x01":
            return i
    return None


def scenario_click(r: Rime, mode: str, transcript: list[str]) -> None:
    hdr(f"M3 点选拦截（候选 text 模式 = {mode}）")
    r.set_option("t9_empty_text", mode == "empty")
    r.set_option("t9_marker_text", mode == "marker")

    r.clear()
    r.set_input("94343")
    before = r.input()
    cands = r.candidates()
    print(f"   改前 input={before!r}  preedit={r.preedit()!r}")
    show_candidates(r)

    idx = find_syllable_cand(cands, "zhe")
    if idx is None:
        print("   [FAIL] 候选里找不到 'zhe' 音节候选")
        transcript.append(f"[{mode}] FAIL: 无 zhe 候选")
        return
    print(f"\n   选中第 {idx} 个候选（zhe）—— 用 select_candidate_on_current_page({idx})")
    ok = r.select(idx)
    print(f"   select() 返回 {ok}")

    after = r.input()
    comm = r.take_commit()
    print(f"   改后 input    = {after!r}")
    print(f"   改后 preedit  = {r.preedit()!r}")
    print(f"   commit 泄漏   = {comm!r}")
    show_candidates(r)

    ok_rewrite = (after == "zhe'43")
    leaked = comm != ""
    print(f"\n   >> 改写成功? {ok_rewrite}   有文本上屏泄漏? {leaked}")
    transcript.append(
        f"[{mode}] 94343 --select(zhe)--> input={after!r} commit={comm!r} "
        f"rewrite_ok={ok_rewrite} leak={leaked}")
    r.set_option("t9_empty_text", False)
    r.set_option("t9_marker_text", False)


def scenario_relay(r: Rime, transcript: list[str]) -> None:
    hdr("M4 混合接力：input 已是 zhe'43（字母精确拼音 + 撇号 + 数字 T9）")
    for text, want in (("zhe'43", "这个"), ("zhe'94", "这西"), ("xi'34", "西地")):
        print(f"\n-- set_input({text!r}) 期望出现 {want!r} --")
        r.clear()
        r.set_input(text)
        print(f"   context.input = {r.input()!r}")
        show_candidates(r)
        cands = r.candidates()
        hit = any(t == want for t, _ in cands)
        print(f"   >> 命中 {want!r}? {hit}")
        transcript.append(
            f"[M4 {'PASS' if hit else 'FAIL'}] input={text} want={want} -> "
            f"cands={[t for t, _ in cands[:8]]}")


def scenario_processor(r: Rime, transcript: list[str]) -> None:
    hdr("兜底：lua_processor 按键循环切分（Tab）")
    r.clear()
    r.set_input("94343")
    print(f"   起始 input={r.input()!r}")
    seen = []
    for i in range(8):
        if not r.key("Tab"):
            print(f"   Tab 第 {i+1} 次未被消费（process_key 返回 0）")
            break
        cur = r.input()
        seen.append(cur)
        print(f"   Tab #{i+1} -> input={cur!r}  preedit={r.preedit()!r}")
    transcript.append(f"[processor] Tab 循环结果：{seen}")


def scenario_typed_keys(r: Rime, transcript: list[str]) -> None:
    hdr("对照：真正逐键敲 94343（process_key 数字键，而非 set_input）")
    r.clear()
    for ch in "94343":
        r.key(ch)
    print(f"   context.input={r.input()!r}  preedit={r.preedit()!r}")
    show_candidates(r)
    transcript.append(f"[typed] 94343 -> input={r.input()!r}")


# ---------------------------------------------------------------------------
def cmd_run(mode: str) -> int:
    sync_sources()
    log = LOG_DIR / "t9_debug.log"
    if log.exists():
        log.unlink()
    os.environ["T9_LOG"] = str(log)

    r = Rime(USER_DIR)
    print(f"== librime {r.version}，当前方案 = {r.schema()}")
    if r.schema() != "t9prot":
        r.select_schema("t9prot")
        print(f"== 切换到方案 = {r.schema()}")

    transcript: list[str] = []
    try:
        scenario_enumerate(r, transcript)
        scenario_click(r, mode, transcript)
        scenario_relay(r, transcript)
        scenario_processor(r, transcript)
        scenario_typed_keys(r, transcript)
    finally:
        r.close()

    print()
    print("=" * 78)
    print("LUA 内部日志（t9_debug.log）")
    print("=" * 78)
    if log.exists():
        for line in log.read_text(encoding="utf-8", errors="replace").splitlines():
            print("   " + line)

    TRANSCRIPT.mkdir(parents=True, exist_ok=True)
    (TRANSCRIPT / f"run_{mode}.txt").write_text("\n".join(transcript) + "\n", encoding="utf-8")
    print(f"\n== 场景摘要已写入 transcripts/run_{mode}.txt")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["all", "deploy", "run"], nargs="?", default="all")
    ap.add_argument("--mode", choices=["text", "empty", "marker"], default="empty")
    args = ap.parse_args()

    if args.cmd == "deploy":
        return cmd_deploy()
    if args.cmd == "run":
        return cmd_run(args.mode)

    rc = cmd_deploy()
    if rc:
        return rc
    print("\n" + "#" * 78)
    print("# 另起进程跑场景（避免 deployer/engine 同进程互相干扰）")
    print("#" * 78)
    return subprocess.call([sys.executable, str(Path(__file__).resolve()), "run", "--mode", args.mode])


if __name__ == "__main__":
    raise SystemExit(main())
