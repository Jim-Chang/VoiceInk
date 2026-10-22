#!/usr/bin/env python3
"""比較 TEA 批次辨識各組設定的結果(docs/plan/2026-10-23-tea-batch.md)。

讀 tea_batch_run.sh 的輸出(名稱.jsonl、名稱.time),每組和基準(第一個 --run)比:
  - 時間:語音辨識總時間(含重跑)、主要那輪、重跑、批數;倍數 = 基準時間 / 這組時間。
  - 記憶體:/usr/bin/time -l 的 peak memory footprint、maximum resident set size。
  - 卡住的段:第一次跑就停下的 App 段數、切兩半重跑幾次、最後還是停下(只留部分文字)幾段。
  - 文字:和基準逐字相同的單位數、差異字數(編輯距離)佔全部字數的比例、差異的類型。
    比之前照 App 的 ZhTWTranscript.clean 拿掉私用區字元和 TEA 零星的全形標點;另外也記不清理的逐字相同數。
    --unit chunk:以 App 的一段為單位(會議錄音);--unit item:以一個錄音為單位(短句)。

用法:
  python3 -I scripts/bench/tea_batch_compare.py --dir 輸出資料夾 --unit chunk --run b1 --run b2 … --out stats.json
  [--diffs diffs.json]:另外寫出每個不同的地方(含文字),只給私人 repo 用;不給就只有統計。
畫面上只印統計,不印內容。
"""
import argparse
import difflib
import json
import re
from pathlib import Path

PUNCTUATION = set("，。、？！：；「」『』（）《》…")


def clean(text):
    text = "".join(ch for ch in text if not 0xE000 <= ord(ch) <= 0xF8FF)
    return "".join(ch for ch in text if ch not in PUNCTUATION).strip()


def edit_distance(a, b):
    if len(a) < len(b):
        a, b = b, a
    previous = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        current = [i]
        for j, cb in enumerate(b, 1):
            current.append(min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (ca != cb)))
        previous = current
    return previous[-1]


def kind(op, old, new):
    """一處差異的類型(只看字的種類,不看內容)。"""
    if re.search(r"[A-Za-z0-9]", old + new):
        return "英文或數字"
    if op == "insert":
        return "多字"
    if op == "delete":
        return "少字"
    return "換字" if len(old) == len(new) else "換字且字數不同"


def load(directory, name):
    rows = [json.loads(line) for line in (directory / f"{name}.jsonl").read_text(encoding="utf-8").splitlines() if line]
    items = [r for r in rows if "id" in r]
    summary = next(r for r in rows if r.get("summary"))
    batches = [r for r in rows if "batch" in r and "depth" in r]
    warmup = next(r for r in rows if r.get("warmup"))
    time_text = (directory / f"{name}.time").read_text(encoding="utf-8", errors="replace")
    memory = {}
    for key, pattern in (("peak_footprint_bytes", r"(\d+)\s+peak memory footprint"),
                         ("max_rss_bytes", r"(\d+)\s+maximum resident set size")):
        m = re.search(pattern, time_text)
        memory[key] = int(m.group(1)) if m else None
    m = re.search(r"([\d.]+) real", time_text)
    memory["process_seconds"] = float(m.group(1)) if m else None
    return items, summary, batches, warmup, memory


def units(items, unit):
    """{單位: (原始文字, 第一次狀態)}"""
    out = {}
    for item in items:
        if unit == "item":
            out[item["id"]] = (item["text"], "ok" if all(c["status"] == "ok" for c in item["chunks"]) else "stopped")
        else:
            for c in item["chunks"]:
                out[f'{item["id"]}@{c["start"]:.3f}'] = (c["text"], c["status"])
    return out


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dir", required=True)
    parser.add_argument("--unit", choices=["chunk", "item"], required=True)
    parser.add_argument("--run", action="append", required=True, help="第一個是基準")
    parser.add_argument("--out", required=True)
    parser.add_argument("--diffs")
    args = parser.parse_args()

    directory = Path(args.dir)
    loaded = {name: load(directory, name) for name in args.run}
    base_name = args.run[0]
    base_items, base_summary, _, _, base_memory = loaded[base_name]
    base_units = units(base_items, args.unit)
    base_chars = sum(len(clean(t)) for t, _ in base_units.values())

    stats = {"unit": args.unit, "baseline": base_name, "units": len(base_units), "baseline_chars": base_chars, "runs": {}}
    all_diffs = {}
    for name in args.run:
        items, summary, batches, warmup, memory = loaded[name]
        run_units = units(items, args.unit)
        assert run_units.keys() == base_units.keys(), f"{name}: 段落和基準對不上"
        identical = identical_raw = 0
        distance = 0
        kinds = {}
        diffs = []
        for key, (base_text, _) in base_units.items():
            text = run_units[key][0]
            identical_raw += text == base_text
            a, b = clean(base_text), clean(text)
            if a == b:
                identical += 1
                continue
            d = edit_distance(a, b)
            distance += d
            entry = {"unit": key, "distance": d, "changes": []}
            for op, i1, i2, j1, j2 in difflib.SequenceMatcher(None, a, b, autojunk=False).get_opcodes():
                if op == "equal":
                    continue
                k = kind(op, a[i1:i2], b[j1:j2])
                kinds[k] = kinds.get(k, 0) + 1
                entry["changes"].append({"kind": k, "baseline": a[i1:i2], "this": b[j1:j2],
                                         "context": a[max(0, i1 - 8):i2 + 8]})
            diffs.append(entry)
        first_stopped = sum(1 for _, status in run_units.values() if status != "ok")
        main_batches = [b for b in batches if b["depth"] == 0]
        stats["runs"][name] = {
            "batch": summary["batch"],
            "sort_length": warmup["sort_length"],
            "total_s": round(summary["total_ms"] / 1000, 1),
            "main_s": round(summary["main_ms"] / 1000, 1),
            "retry_s": round(summary["retry_ms"] / 1000, 1),
            "session_s": round(summary["session_ms"] / 1000, 2),
            "speedup": round(base_summary["total_ms"] / summary["total_ms"], 2),
            "load_s": round(warmup["load_ms"] / 1000, 2),
            "warmup_s": round(warmup["wall_ms"] / 1000, 2),
            "process_s": memory["process_seconds"],
            "batches": summary["batches"],
            "runs": summary["runs"],
            "main_batch_s_median": sorted(b["wall_ms"] for b in main_batches)[len(main_batches) // 2] / 1000
            if main_batches else None,
            "encode_s": round(sum(b["encode_ms"] for b in batches) / 1000, 1),
            "decode_s": round(sum(b["decode_ms"] for b in batches) / 1000, 1),
            "peak_footprint_gb": round(memory["peak_footprint_bytes"] / 1e9, 2) if memory["peak_footprint_bytes"] else None,
            "max_rss_gb": round(memory["max_rss_bytes"] / 1e9, 2) if memory["max_rss_bytes"] else None,
            "peak_footprint_delta_gb": round((memory["peak_footprint_bytes"] - base_memory["peak_footprint_bytes"]) / 1e9, 2)
            if memory["peak_footprint_bytes"] and base_memory["peak_footprint_bytes"] else None,
            "first_stopped": first_stopped,
            "retried": summary["retried"],
            "still_stopped": summary["truncated"],
            "failed": summary["failed"],
            "identical": identical,
            "identical_ratio": round(identical / len(base_units), 4),
            "identical_raw": identical_raw,
            "diff_chars": distance,
            "diff_ratio": round(distance / base_chars, 5) if base_chars else None,
            "diff_kinds": kinds,
        }
        all_diffs[name] = diffs
        r = stats["runs"][name]
        print(f'{name}: 批次 {r["batch"]}{"(依長度)" if r["sort_length"] else ""} 總 {r["total_s"]} 秒'
              f'(重跑 {r["retry_s"]})×{r["speedup"]},尖峰 {r["peak_footprint_gb"]}GB({r["peak_footprint_delta_gb"]:+}),'
              f'第一次停下 {r["first_stopped"]}、重跑 {r["retried"]}、最後還停下 {r["still_stopped"]};'
              f'逐字相同 {identical}/{len(base_units)}(不清理 {identical_raw}),差異 {distance} 字'
              f'({r["diff_ratio"]:.3%}){kinds}')
    Path(args.out).write_text(json.dumps(stats, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    if args.diffs:
        Path(args.diffs).write_text(json.dumps(all_diffs, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
