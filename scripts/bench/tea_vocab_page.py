#!/usr/bin/env python3
"""TEA 詞彙表的量測:把「要聽錄音才能判斷」的差異做成給使用者的頁面(錄音以 AAC 嵌在頁面裡)。

做法見 docs/plan/2026-10-22-tea-vocabulary.md。輸入、輸出都放私人 repo。

  tea_vocab_page.py <history.json> <items.json> <page.html> <key.json> [--seed 1]

items.json 是 tea_vocab_diff.py 的 spots.json 裡挑出來的項目(至少要有 id、pair、old_marked、new_marked),
可以再加 "calibration": true 標出用來檢查文字判斷的題目(頁面上看不出來)。
每題 A/B 哪個是新版隨機決定、兩邊各半;答案(哪個是新版、原本的項目)寫進 key.json。
使用者選完按「產生結果」,把那一行貼回對話。
"""
import base64
import html
import json
import os
import random
import subprocess
import sys
import tempfile


def aac_data_uri(wav):
    with tempfile.TemporaryDirectory() as tmp:
        out = os.path.join(tmp, "a.m4a")
        subprocess.run(["afconvert", "-f", "m4af", "-d", "aac", "-b", "64000", wav, out], check=True)
        data = open(out, "rb").read()
    return "data:audio/mp4;base64," + base64.b64encode(data).decode()


def marked(text):
    return html.escape(text).replace("⟦", "<mark>").replace("⟧", "</mark>")


def main(argv):
    if len(argv) < 4:
        sys.exit(__doc__)
    history, items_path, page_path, key_path = argv[:4]
    seed = int(argv[argv.index("--seed") + 1]) if "--seed" in argv else 1
    base = os.path.dirname(os.path.abspath(history))
    clips = {it["id"]: it for it in json.load(open(history, encoding="utf-8"))}
    items = json.load(open(items_path, encoding="utf-8"))
    rng = random.Random(seed)
    order = list(range(len(items)))
    rng.shuffle(order)
    half = len(items) // 2 + (rng.randint(0, 1) if len(items) % 2 else 0)
    new_is_a = [True] * half + [False] * (len(items) - half)
    rng.shuffle(new_is_a)

    sections, key = [], []
    for n, idx in enumerate(order, 1):
        item = items[idx]
        clip = clips[item["id"]]
        wav = os.path.normpath(os.path.join(base, clip["recording"]))
        a, b = (item["new_marked"], item["old_marked"]) if new_is_a[n - 1] else (item["old_marked"], item["new_marked"])
        opts = "".join(
            f'<label class="opt"><input type="radio" name="q{n}" value="{v}"><b>{v}</b><span>{t}</span></label>'
            for v, t in (("A", marked(a)), ("B", marked(b)), ("=", "兩個都對(只是寫法不同)"), ("X", "兩個都錯"))
        )
        sections.append(
            f'<section><h3>第 {n} 題({clip["duration"]:.1f} 秒)</h3>'
            f'<audio controls preload="auto" src="{aac_data_uri(wav)}"></audio>{opts}</section>'
        )
        key.append({"q": n, "new_is": "A" if new_is_a[n - 1] else "B", **item})

    page = f"""<!doctype html><html lang="zh-Hant"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>詞彙表判斷</title><style>
:root{{--bg:#fff;--fg:#1d1d1f;--mut:#6e6e73;--line:#d2d2d7;--hi:#eef4ff;--mark:#ffe58a}}
@media (prefers-color-scheme:dark){{:root{{--bg:#1c1c1e;--fg:#f2f2f7;--mut:#a1a1a6;--line:#3a3a3c;--hi:#1f2a3d;--mark:#6b5a00}}}}
body{{background:var(--bg);color:var(--fg);font:16px/1.6 -apple-system,"PingFang TC",sans-serif;max-width:860px;margin:0 auto;padding:16px}}
section{{border-top:1px solid var(--line);padding:12px 0}} h3{{margin:4px 0 8px;font-size:15px;color:var(--mut)}}
audio{{width:100%;margin-bottom:8px}} .opt{{display:flex;gap:10px;padding:8px;border-radius:8px;cursor:pointer}}
.opt:has(input:checked){{background:var(--hi)}} .opt b{{min-width:1.2em}} mark{{background:var(--mark);color:inherit;border-radius:3px}}
textarea{{width:100%;height:4em;font:14px monospace}} button{{font-size:15px;padding:6px 14px}} p.note{{color:var(--mut)}}
</style></head><body>
<h1>詞彙表判斷</h1>
<p class="note">每題先聽錄音,看<mark>標出來的地方</mark>哪個版本和你實際講的一樣。兩個都對(例如只是大小寫或寫法不同)選「=」,都不對選「X」。標點已拿掉,只看字。A、B 每題隨機。</p>
{''.join(sections)}
<p><button onclick="gen()">產生結果</button></p><textarea id="out" readonly></textarea>
<script>
function gen(){{
  const t='詞彙表 '+[...Array({len(items)}).keys()].map(i=>{{const e=document.querySelector('input[name=q'+(i+1)+']:checked');return (i+1)+':'+(e?e.value:'-')}}).join(' ');
  const o=document.getElementById('out'); o.value=t; o.select();
  try{{navigator.clipboard.writeText(t)}}catch(e){{}}
}}
</script></body></html>
"""
    open(page_path, "w", encoding="utf-8").write(page)
    json.dump(key, open(key_path, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print(f"{len(items)} questions, new version is A in {sum(new_is_a)}")


if __name__ == "__main__":
    main(sys.argv[1:])
