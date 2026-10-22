#!/usr/bin/env python3
"""比較 TEA 辨識「語音偵測切段」開、關的結果(長音檔計畫的步驟 4)。

做法:
  - 關:tc_bench 直接跑原始錄音,每 30 秒在最安靜的地方切(和 App 的 energyAwareChunks 同一套)。
  - 開:segment-bench(App 同一份 TranscribeCppSpeechSegmenter)切出講話的段,存成 wav,
        再用 tc_bench 跑;超過 30 秒的講話一樣交給 tc_bench 切。各段照順序接回同一個錄音。
  - 兩邊都拿掉私用區字元和 TEA 零星的全形標點再比(App 的 ZhTWTranscript.clean 也會拿掉)。

用法(跑的時候不要聽寫、不要跑其他評測):
  python3 -I scripts/bench/vad_compare.py --tc-bench tc_bench --model TEA.gguf \\
      --recordings 錄音資料夾 --work 暫存資料夾 --out 私人 repo 的輸出資料夾 [segment-bench 的參數…]
輸出:baseline.jsonl、vad.jsonl(tc_bench 原始輸出)、segments.jsonl(切段統計)、compare.json(逐段比較)。
畫面上只印統計,不印內容。
"""
import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
PUNCTUATION = set("，。、？！：；「」『』（）《》…")


def clean(text):
    text = "".join(ch for ch in text if not 0xE000 <= ord(ch) <= 0xF8FF)
    return "".join(ch for ch in text if ch not in PUNCTUATION).strip()


def run_tc_bench(args, listing, output):
    """已經有輸出就直接用(重跑比較時省一次辨識)。第一行是暖機,不算。"""
    if not output.exists():
        subprocess.run([args.tc_bench, "-m", args.model, "-i", str(listing), "-o", str(output), "-l", "zh",
                        "--itn", "default", "--max-chunk-sec", "30", "--boundary-sec", "3", "--window", "1600"],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    rows = [json.loads(line) for line in output.read_text(encoding="utf-8").splitlines() if line.strip()]
    return [row for row in rows if "id" in row]


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tc-bench", required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--recordings", required=True)
    parser.add_argument("--work", required=True)
    parser.add_argument("--out", required=True)
    args, segment_args = parser.parse_known_args()

    work, out = Path(args.work), Path(args.out)
    work.mkdir(parents=True, exist_ok=True)
    out.mkdir(parents=True, exist_ok=True)
    wavs = sorted(Path(args.recordings).glob("*.wav"))
    listing = work / "all.tsv"
    listing.write_text("".join(f"{w.stem}\t{w}\n" for w in wavs), encoding="utf-8")

    print(f"關:{len(wavs)} 段原始錄音", file=sys.stderr)
    baseline = {r["id"]: r for r in run_tc_bench(args, listing, out / "baseline.jsonl")}

    print("開:語音偵測切段", file=sys.stderr)
    segment_output = subprocess.run(
        [str(HERE / "segment-bench.sh"), "--no-split", "--wav-dir", str(work / "vad"), "--list", str(listing)]
        + segment_args, check=True, capture_output=True, text=True).stdout
    (out / "segments.jsonl").write_text(segment_output, encoding="utf-8")
    segments = {s["id"]: s for s in map(json.loads, segment_output.splitlines())}
    vad_rows = run_tc_bench(args, work / "vad" / "list.tsv", out / "vad.jsonl")

    vad = {}
    for row in vad_rows:
        recording = row["id"].rsplit("__", 1)[0]
        vad.setdefault(recording, {"text": "", "wall_ms": 0.0})
        vad[recording]["text"] += row.get("text") or ""
        vad[recording]["wall_ms"] += row.get("wall_ms", 0.0)

    rows = []
    for w in wavs:
        base_text = clean(baseline.get(w.stem, {}).get("text") or "")
        vad_text = clean(vad.get(w.stem, {}).get("text", ""))
        seg = segments.get(w.stem, {})
        rows.append({
            "id": w.stem, "seconds": seg.get("seconds"), "speechSeconds": seg.get("speechSeconds"),
            "chunks": seg.get("chunks"), "vadMs": seg.get("vadMs"),
            "same": base_text == vad_text, "baseChars": len(base_text), "vadChars": len(vad_text),
            "baseMs": baseline.get(w.stem, {}).get("wall_ms"), "vadAsrMs": vad.get(w.stem, {}).get("wall_ms"),
            "baseline": base_text, "vad": vad_text,
        })
    (out / "compare.json").write_text(json.dumps(rows, ensure_ascii=False, indent=1), encoding="utf-8")

    same = sum(r["same"] for r in rows)
    vad_ms = sorted(r["vadMs"] or 0 for r in rows)
    removed = sum((r["seconds"] or 0) - (r["speechSeconds"] or 0) for r in rows)
    total = sum(r["seconds"] or 0 for r in rows)
    print(f"逐字相同 {same}/{len(rows)};字數 關 {sum(r['baseChars'] for r in rows)} / 開 {sum(r['vadChars'] for r in rows)};"
          f"丟掉的音訊 {removed:.0f}/{total:.0f} 秒;語音偵測中位 {vad_ms[len(vad_ms) // 2]:.0f} ms、最大 {vad_ms[-1]:.0f} ms")
    for r in rows:
        if not r["same"]:
            print(f"  不同:{r['id'][:8]} {r['seconds']} 秒 字數 {r['baseChars']} → {r['vadChars']}")


if __name__ == "__main__":
    main()
