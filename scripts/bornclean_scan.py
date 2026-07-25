#!/usr/bin/env python3
"""born-clean 身分掃描 —— gitleaks 管「秘密」，這支管「身分」。

兩者互補、不重疊：
  gitleaks  → token / key / 憑證這類**有固定形狀的秘密**
  本腳本    → 真名、機器名、絕對家目錄路徑、真實座標、真實地點名這類**私域身分**
              （見 CLAUDE.md 紅線第二條：零私域身分進 git，含 code / docs / commit message）

🔴 **站點專屬的字詞不寫在這個檔裡。** 那些字本身就是私域內容，寫進來等於把要防的東西
   放進要保護的 repo。改放 gitignored 的 deny-list（預設 `.bornclean-deny`，一行一個
   regex、`#` 開頭是註解）；範本見 `.bornclean-deny.example`。

用法：
    python3 scripts/bornclean_scan.py [路徑]            # 掃工作區
    python3 scripts/bornclean_scan.py --selftest        # 驗掃描器本身抓得到東西

🔴 為什麼有 --selftest：掃描器回報「零命中」可能是真的乾淨，也可能是它自己壞了
   （2026-07-26 實際踩過：regex 經 shell 變數傳遞時轉義被吃掉，掃出假的零命中）。
   pre-push hook 每次都先跑自我測試，過了才相信它說的乾淨。
"""
from __future__ import annotations

import re
import sys
import pathlib

DENY_FILE = ".bornclean-deny"
SKIP_DIRS = {".git", "node_modules", ".claude", "screenshots", ".build", "DerivedData"}
SKIP_SUFFIX = {".png", ".jpg", ".jpeg", ".gif", ".pdf", ".ico", ".zip", ".mp4", ".svg"}

# 通用結構樣態（不含任何站點專屬字詞）
GENERIC: list[tuple[str, str]] = [
    ("絕對家目錄路徑", r"/(?:Users|home)/(?!YOURNAME\b|<)[A-Za-z0-9._-]{2,}"),
    ("私網 IP（完整四段）", r"\b(?:10|192\.168|172\.(?:1[6-9]|2\d|3[01]))\.\d{1,3}\.\d{1,3}\b"),
    ("公網 IP", r"\b(?!0)(?!10\.)(?!127\.)(?!192\.168\.)(?!172\.(?:1[6-9]|2\d|3[01])\.)"
                r"(?:\d{1,3}\.){3}\d{1,3}\b"),
    ("疑似真實座標對", r"\b-?\d{1,3}\.\d{5,}\s*,\s*-?\d{1,3}\.\d{5,}\b"),
    ("email", r"\b[\w.+-]+@(?!email\.com\b|example\.[a-z]+\b)[\w-]+\.[\w.]{2,}\b"),
]

ALLOW_SUBSTR = (      # 明確的佔位/公開常數，不算命中
    "192.168.x.x", "0.0.0.0", "127.0.0.1", "255.255.255.255",
    "/Users/YOURNAME", "supabase-demo",
)

# 行內豁免標記：在該行任意處寫上這串就跳過。刻意用「明示在原地」而不是集中式忽略清單——
# 忽略清單會累積、沒人會回頭審；寫在原地的話，看到那行的人一定會看到豁免理由。
ALLOW_MARK = "bornclean:allow"

# 私有限定文件：**絕不鏡像到公開版**的那幾份（實測劇本、夜間紀錄、bug log 之類）。
# 它們刻意含操作真值，所以不掃；但掃描器會把清單印出來當提醒，不是靜默跳過——
# 「哪些檔不能外流」值得有一個明文的單一來源，而不是靠人記得。
#
# 🔴 清單同樣走 deny-list 檔（`skip:` 開頭的行），不寫死在這裡：哪些檔案是私有的
#    也是站點資訊。這支腳本本身要能原封不動地放進公開 repo。


def deny_path(root: pathlib.Path) -> pathlib.Path | None:
    """找 deny-list：① 環境變數 BORNCLEAN_DENY ② 本目錄 ③ **主 worktree**。

    第 ③ 個是必要的：deny-list 是 gitignored，而 git worktree **不共用未追蹤檔案**，
    所以在 worktree 裡跑會找不到它、於是私有限定檔全被掃、hook 每次都紅。
    （2026-07-26 實際踩到。）
    """
    import os, subprocess
    env = os.environ.get("BORNCLEAN_DENY")
    if env and pathlib.Path(env).expanduser().exists():
        return pathlib.Path(env).expanduser()
    if (root / DENY_FILE).exists():
        return root / DENY_FILE
    try:
        common = subprocess.run(["git", "rev-parse", "--git-common-dir"], cwd=root,
                                capture_output=True, text=True, timeout=10)
        if common.returncode == 0:
            main_root = (root / common.stdout.strip()).resolve().parent
            cand = main_root / DENY_FILE
            if cand.exists():
                return cand
    except (OSError, subprocess.SubprocessError):
        pass
    return None


def load_deny(root: pathlib.Path) -> tuple[list[tuple[str, str]], set[str]]:
    """回 (regex 規則, 私有限定路徑)。`skip:` 開頭的行是路徑、其餘是 regex。"""
    f = deny_path(root)
    if f is None:
        return [], set()
    out: list[tuple[str, str]] = []
    skip: set[str] = set()
    for i, line in enumerate(f.read_text(encoding="utf-8").splitlines(), 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("skip:"):
            skip.add(line[5:].strip())
            continue
        try:
            re.compile(line)
        except re.error as e:
            print(f"  ⚠️  {DENY_FILE}:{i} 不是合法 regex，已略過：{e}", file=sys.stderr)
            continue
        out.append((f"deny-list:{i}", line))
    return out, skip


def scan(root: pathlib.Path, rules: list[tuple[str, str]],
         skipped: list | None = None, private_only: set[str] | None = None) -> int:
    hits = 0
    skipped = skipped if skipped is not None else []
    private_only = private_only or set()
    for p in sorted(root.rglob("*")):
        if not p.is_file():
            continue
        # 🔴 用「相對 root」的路徑比對，不是絕對路徑：repo 若剛好位在名字撞 SKIP_DIRS 的
        # 目錄底下（例如 git worktree 放在 .claude/worktrees/），拿絕對路徑比會把**每一個檔**
        # 都跳過，然後安靜地回報「乾淨」。2026-07-26 實際踩過。
        rel = p.relative_to(root)
        if any(d in rel.parts for d in SKIP_DIRS):
            continue
        rp = rel.as_posix()
        if any(rp == sp or rp.startswith(sp.rstrip("/") + "/") for sp in private_only):
            skipped.append(rp)
            continue
        if p.suffix.lower() in SKIP_SUFFIX or p.name == DENY_FILE:
            continue
        try:
            text = p.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        lines = text.splitlines()
        for label, pat in rules:
            for m in re.finditer(pat, text):
                ln = text[:m.start()].count("\n")
                line = lines[ln] if ln < len(lines) else ""
                if ALLOW_MARK in line or any(a in line for a in ALLOW_SUBSTR):
                    continue
                print(f"  🔴 [{label}] {p.relative_to(root)}:{ln + 1}  {line.strip()[:120]}")
                hits += 1
    return hits


def selftest() -> int:
    """種一段必定命中的內容，確認掃描器真的會叫。"""
    import tempfile, os
    with tempfile.TemporaryDirectory() as d:
        # 刻意把 root 放在一個名字撞 SKIP_DIRS 的目錄底下，回歸「絕對路徑比對」那個假陰性
        root = pathlib.Path(d) / ".claude" / "worktrees" / "canary-repo"
        root.mkdir(parents=True)
        (root / "canary.txt").write_text(
            "/Users/somebody/dev/x\n192.168.1.23\n24.123456, 120.654321\nsomeone@example.org\n",  # bornclean:allow（這是 canary、不是真值）
            encoding="utf-8")
        (root / DENY_FILE).write_text("秘密地點名\nskip:private/\n", encoding="utf-8")
        (root / "canary2.txt").write_text("這裡提到秘密地點名\n", encoding="utf-8")
        (root / "private").mkdir()
        (root / "private" / "leaky.txt").write_text("192.168.9.9\n", encoding="utf-8")  # bornclean:allow（canary）
        rules, skip = load_deny(root)
        sk: list[str] = []
        n = scan(root, GENERIC + rules, sk, skip)
        if not sk:
            print("✗ 自我測試失敗：skip: 規則沒生效。", file=sys.stderr); return 1
    if n < 4:
        print(f"✗ 自我測試失敗：預期至少 4 個命中，實得 {n} —— 掃描器壞了，不要相信它說的乾淨。",
              file=sys.stderr)
        return 1
    print(f"✓ 掃描器自我測試通過（canary 置於 .claude/worktrees/ 底下、抓到 {n} 個）。")
    return 0


def main() -> int:
    if "--selftest" in sys.argv:
        return selftest()
    root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    deny_rules, private_only = load_deny(root)
    rules = GENERIC + deny_rules
    dp = deny_path(root)
    if dp is None:
        print(f"  ⚠️  找不到 {DENY_FILE} —— 只跑通用樣態。站點專屬字詞請照 "
              f"{DENY_FILE}.example 建一份（該檔已 gitignore）。")
    elif dp.parent != root:
        print(f"  ℹ️  deny-list 取自 {dp}")
    skipped: list[str] = []
    hits = scan(root, rules, skipped, private_only)
    if skipped:
        print(f"  ℹ️  跳過 {len(skipped)} 份私有限定文件（含操作真值、**絕不鏡像到公開版**）：")
        for f in sorted(set(skipped))[:8]:
            print(f"       {f}")
    if hits:
        print(f"\n✗ born-clean 掃描命中 {hits} 處 —— 確認是誤報再放行。")
        return 1
    print("✓ born-clean 掃描無命中。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
