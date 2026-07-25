#!/usr/bin/env python3
"""文件 lint —— 只做兩件本機看不出來、但推上去會壞的事。

1. **mermaid 真的渲染得出來**：VS Code 預覽可能寬容、GitHub 上壞掉就是一塊紅字。
   用 mmdc 實際產圖，不靠讀語法猜。
2. **相對連結指得到**：改檔名／搬文件時最容易斷，而且沒人會逐個點。

刻意不做 markdownlint：這 repo 是中文散文為主，那些規則多半在管英文排版慣例，噪音大於價值。
"""
from __future__ import annotations
import re, sys, pathlib, subprocess, tempfile, shutil

SKIP = {".git", "node_modules", ".claude"}

def md_files(root):
    # 🔴 比對「相對 root」的路徑：repo 若位在名字撞 SKIP 的目錄下（如 git worktree 放在
    # .claude/worktrees/），拿絕對路徑比會把每個檔都跳過，然後安靜地說「全過」。
    return [p for p in sorted(root.rglob("*.md"))
            if not any(d in p.relative_to(root).parts for d in SKIP)]

def lint_links(root) -> int:
    bad = tot = 0
    for md in md_files(root):
        text = md.read_text(encoding="utf-8")
        for m in re.finditer(r"\[([^\]]*)\]\(([^)]+)\)", text):
            tgt = m.group(2).split("#")[0].strip()
            if not tgt or tgt.startswith(("http://", "https://", "mailto:")):
                continue
            tot += 1
            if not (md.parent / tgt).resolve().exists():
                bad += 1
                ln = text[:m.start()].count("\n") + 1
                print(f"  🔴 連結失效 {md.relative_to(root)}:{ln}  [{m.group(1)}]({tgt})")
    print(f"  相對連結 {tot} 個，失效 {bad} 個")
    return bad

def lint_mermaid(root) -> int:
    if not shutil.which("mmdc"):
        print("  ⚠️  mmdc 未安裝，跳過 mermaid 渲染檢查"
              "（裝：npm i -g @mermaid-js/mermaid-cli）")
        return 0
    out = pathlib.Path(tempfile.mkdtemp()); fail = tot = 0
    for md in md_files(root):
        text = md.read_text(encoding="utf-8")
        for i, m in enumerate(re.finditer(r"```mermaid\n(.*?)\n```", text, flags=re.S), 1):
            tot += 1
            ln = text[:m.start()].count("\n") + 1
            src = out / f"{md.stem}_{i}.mmd"; src.write_text(m.group(1), encoding="utf-8")
            r = subprocess.run(["mmdc", "-i", str(src), "-o", str(out / f"{md.stem}_{i}.svg"), "-q"],
                               capture_output=True, text=True, timeout=180)
            if r.returncode != 0:
                fail += 1
                print(f"  🔴 mermaid 渲染失敗 {md.relative_to(root)}:{ln}")
                for l in [x for x in (r.stderr or r.stdout).splitlines() if x.strip()][-3:]:
                    print("       " + l[:150])
    print(f"  mermaid {tot} 張，失敗 {fail} 張")
    return fail

def main() -> int:
    root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    n_md = len(md_files(root))
    if n_md == 0:
        print("✗ 一個 .md 都沒掃到 —— 這通常代表路徑或跳過規則有問題，不是真的沒文件。")
        return 1
    print(f"  掃描 {n_md} 份文件")
    n = lint_links(root) + lint_mermaid(root)
    print("✗ 文件 lint 未過。" if n else "✓ 文件 lint 通過。")
    return 1 if n else 0

if __name__ == "__main__":
    sys.exit(main())
