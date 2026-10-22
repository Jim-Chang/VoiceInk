#!/usr/bin/env python3
"""換語音辨識模型的調查:整理 asr_models_run.sh 的輸出、算統計、產生盲評題目。

子指令(輸入輸出都放私人 repo,這支程式只放公開 fork):
  collect  <run 資料夾> <transcripts.json> <results.json>   整理各模型的辨識結果、時間、記憶體
  combine  <results.json> <第一輪> <第二輪> <切段第一輪> <切段第二輪>   兩輪合併(時間取較快的一次)
  stats    <results.json> <stats.json>                     速度、和 Breeze 的差異、標點、英文、簡體字
  convdiff <results.json> <convdiff.json>                  簡轉繁之後和原生繁體模型不同的字
  blind    <results.json> <blinded.json> <key.json>        辨識盲評題目(A/B/C… 每題隨機,答案另存)
  unblind  <results.json> <key.json> <review.json> <out.json>  Sonnet 的判斷對回模型

文字處理:
- 刪掉私用區字元(TEA 的 tokenizer 標記)和 whisper 偶爾留下的 <|…|> 標記。
- 簡體輸出的模型(qwen*、sensevoice、funasr-nano)用 OpenCC s2twp 轉成繁體,就是會貼出來的樣子。
- 比較內容時「折疊」:NFKC、去掉標點和空白、英文轉小寫、OpenCC t2s,只看字。
"""
import json
import pathlib
import random
import re
import statistics
import subprocess
import sys
import unicodedata

MODELS = {
    # 代號: (執行方式, 是否原生繁體)
    "breeze": ("whisper.cpp", True),
    "tea": ("transcribe.cpp", True),
    "tea-mini": ("transcribe.cpp", True),
    "qwen": ("transcribe.cpp", False),
    "qwen-mini": ("transcribe.cpp", False),
    "sensevoice": ("transcribe.cpp", False),
    "funasr-nano": ("transcribe.cpp", False),
}
PUA = re.compile("[-]")
WHISPER_TAG = re.compile(r"<\|[^|>]*\|>")
HAN = re.compile("[㐀-䶿一-鿿豈-﫿]")
LATIN_WORD = re.compile(r"[A-Za-z]+(?:[.'+#-][A-Za-z0-9]+)*")
SENTENCE_END = set("。？！?!")


def group_of(duration):
    return "short" if duration <= 5 else "mid" if duration <= 20 else "long"


def opencc(texts, config):
    """OpenCC 命令列(Homebrew 1.1.7),一行一段。"""
    if not texts:
        return []
    joined = "\n".join(t.replace("\n", " ") for t in texts) + "\n"
    out = subprocess.run(["opencc", "-c", config], input=joined, capture_output=True, text=True, check=True).stdout
    lines = out.split("\n")[:len(texts)]
    assert len(lines) == len(texts)
    return lines


def is_punct(ch):
    return unicodedata.category(ch).startswith("P")


def strip_punct(text):
    """去掉標點,保留英文詞之間的空白(給人看的版本)。"""
    kept = "".join(" " if is_punct(c) else c for c in text)
    return re.sub(r"\s+", " ", kept).strip()


def fold_chars(text):
    """比內容用:NFKC、只留字母數字、小寫(t2s 另外做)。"""
    text = unicodedata.normalize("NFKC", text).lower()
    return "".join(c for c in text if unicodedata.category(c)[0] in "LN")


def edit_distance(a, b):
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


def parse_time(path):
    info = {}
    if not path.exists():
        return info
    for line in path.read_text(errors="replace").splitlines():
        m = re.match(r"\s*(\d+)\s+(maximum resident set size|peak memory footprint)", line)
        if m:
            info["max_rss" if m.group(2).startswith("maximum") else "peak_footprint"] = int(m.group(1))
    return info


def collect(run_dir, transcripts_path, out_path):
    run_dir = pathlib.Path(run_dir)
    items = [i for i in json.load(open(transcripts_path, encoding="utf-8")) if i.get("has_audio")]
    durations = {i["id"]: i["duration"] for i in items}
    result = {"durations": durations, "models": {}}
    for name, (runtime, native) in MODELS.items():
        rows, meta = {}, {"runtime": runtime, "native_traditional": native}
        if name == "breeze":
            path = run_dir / "breeze.json"
            if not path.exists():
                continue
            variant = json.load(open(path, encoding="utf-8"))["variants"]["q8"]
            meta["load_s"] = statistics.median(r["load"] for r in variant["rows"].values())
            for item_id, r in variant["rows"].items():
                rows[item_id] = {"raw": r["text"], "seconds": r["transcribe"], "ok": r["ok"]}
        else:
            path = run_dir / f"{name}.jsonl"
            if not path.exists():
                continue
            for line in open(path, encoding="utf-8"):
                r = json.loads(line)
                if r.get("warmup"):
                    meta["load_s"] = r["load_ms"] / 1000
                    continue
                rows[r["id"]] = {"raw": r["text"], "seconds": r["wall_ms"] / 1000, "ok": r["ok"],
                                 "encode_s": r["encode_ms"] / 1000, "decode_s": r["decode_ms"] / 1000,
                                 "chunks": r["n_chunks"]}
        meta.update(parse_time(run_dir / f"{name}.time.txt"))
        ids = list(rows)
        cleaned = [WHISPER_TAG.sub("", PUA.sub("", rows[i]["raw"])).strip() for i in ids]
        meta["pua_rows"] = sum(bool(PUA.search(rows[i]["raw"])) for i in ids)
        meta["tag_rows"] = sum(bool(WHISPER_TAG.search(rows[i]["raw"])) for i in ids)
        texts = cleaned if native else opencc(cleaned, "s2twp")
        for i, c, t in zip(ids, cleaned, texts):
            rows[i]["clean"] = c
            rows[i]["text"] = t
        result["models"][name] = {"meta": meta, "rows": rows}
    json.dump(result, open(out_path, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print("models:", {k: len(v["rows"]) for k, v in result["models"].items()})


def combine(out_path, run1, run2, chunk1, chunk2):
    """兩輪合併:文字要一樣,時間取較快的一次(干擾只會讓時間變長)。
    切段版(追加)的模型,30 秒以上的錄音改用切段的結果,原本整段的結果留在 "whole"。"""
    r1, r2, c1, c2 = (json.load(open(p, encoding="utf-8")) for p in (run1, run2, chunk1, chunk2))
    out = {"durations": r1["durations"], "models": {}}
    for name, m in r1["models"].items():
        rows = {}
        for item_id, a in m["rows"].items():
            b = r2["models"][name]["rows"][item_id]
            assert a["raw"] == b["raw"], (name, item_id)
            row = dict(a)
            row["seconds_runs"] = [a["seconds"], b["seconds"]]
            row["seconds"] = min(a["seconds"], b["seconds"])
            if name in c1["models"] and item_id in c1["models"][name]["rows"]:
                ca, cb = c1["models"][name]["rows"][item_id], c2["models"][name]["rows"][item_id]
                assert ca["raw"] == cb["raw"], (name, item_id, "chunk")
                row = dict(ca, whole={"text": row["text"], "ok": row["ok"], "seconds": row["seconds"]})
                row["seconds_runs"] = [ca["seconds"], cb["seconds"]]
                row["seconds"] = min(ca["seconds"], cb["seconds"])
                row["chunked"] = True
            rows[item_id] = row
        meta = dict(m["meta"])
        meta["load_s"] = min(m["meta"].get("load_s", 0), r2["models"][name]["meta"].get("load_s", 0))
        meta["peak_footprint"] = max(m["meta"].get("peak_footprint", 0), r2["models"][name]["meta"].get("peak_footprint", 0),
                                     c1["models"].get(name, {}).get("meta", {}).get("peak_footprint", 0))
        meta["chunk_seconds"] = 30 if name in c1["models"] or name == "sensevoice" else None
        out["models"][name] = {"meta": meta, "rows": rows}
    json.dump(out, open(out_path, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    for name, m in out["models"].items():
        print(name, "chunked rows", sum(bool(r.get("chunked")) for r in m["rows"].values()),
              "failed", sum(not r["ok"] for r in m["rows"].values()))


def folded_all(results):
    """每個模型每段的折疊文字(t2s)。"""
    out = {}
    for name, m in results["models"].items():
        ids = list(m["rows"])
        simp = opencc([fold_chars(m["rows"][i]["text"]) for i in ids], "t2s")
        out[name] = dict(zip(ids, simp))
    return out


def stats(results_path, out_path):
    results = json.load(open(results_path, encoding="utf-8"))
    durations = results["durations"]
    folded = folded_all(results)
    out = {"groups": {g: sum(group_of(d) == g for d in durations.values()) for g in ("short", "mid", "long")},
           "models": {}}
    for name, m in results["models"].items():
        rows = m["rows"]
        s = {"meta": m["meta"]}
        # 速度
        speed = {}
        for g in ("short", "mid", "long"):
            vals = [r["seconds"] for i, r in rows.items() if group_of(durations[i]) == g and r["seconds"] is not None]
            speed[g] = {"median": statistics.median(vals), "max": max(vals), "n": len(vals)}
        speed["total"] = sum(r["seconds"] for r in rows.values() if r["seconds"] is not None)
        s["speed"] = speed
        s["failed"] = sum(not r["ok"] for r in rows.values())
        s["empty"] = sum(not r["text"].strip() for r in rows.values())
        # 和 Breeze 的差異
        if name != "breeze" and "breeze" in folded:
            errs = tot = same = 0
            for i, f in folded[name].items():
                ref = folded["breeze"].get(i, "")
                errs += edit_distance(ref, f)
                tot += len(ref)
                same += ref == f
            s["vs_breeze"] = {"char_diff_rate": errs / tot, "identical": same}
        # 標點
        texts = [r["text"] for r in rows.values()]
        han = sum(len(HAN.findall(t)) for t in texts)
        puncts = [c for t in texts for c in t if is_punct(c)]
        full = sum(unicodedata.east_asian_width(c) in "FW" for c in puncts)
        counts = {}
        for c in puncts:
            counts[c] = counts.get(c, 0) + 1
        s["punct"] = {
            "rows_with_any": sum(any(is_punct(c) for c in t) for t in texts),
            "rows_with_sentence_end": sum(any(c in SENTENCE_END for c in t) for t in texts),
            "per_100_han": 100 * len(puncts) / han if han else 0,
            "fullwidth": full, "halfwidth": len(puncts) - full,
            "counts": dict(sorted(counts.items(), key=lambda kv: -kv[1])),
        }
        # 英文
        words = [w for t in texts for w in LATIN_WORD.findall(t)]
        s["english"] = {"words": len(words), "rows_with_english": sum(bool(LATIN_WORD.search(t)) for t in texts)}
        s["han_chars"] = han
        out["models"][name] = s
    # 簡體字夾雜(原生繁體的模型):s2tw 後會變的字
    for name, m in results["models"].items():
        if not m["meta"]["native_traditional"]:
            continue
        ids = list(m["rows"])
        texts = [m["rows"][i]["text"] for i in ids]
        conv = opencc(texts, "s2tw")
        leaks = {}
        for t, c in zip(texts, conv):
            if len(t) != len(c):
                continue
            for a, b in zip(t, c):
                if a != b:
                    leaks[f"{a}→{b}"] = leaks.get(f"{a}→{b}", 0) + 1
        out["models"][name]["s2tw_changes"] = leaks
    json.dump(out, open(out_path, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    for name, s in out["models"].items():
        sp = s["speed"]
        print(f"{name:12s} short {sp['short']['median']:.2f}/{sp['short']['max']:.2f} "
              f"mid {sp['mid']['median']:.2f}/{sp['mid']['max']:.2f} long {sp['long']['median']:.2f}/{sp['long']['max']:.2f} "
              f"total {sp['total']:.1f} load {s['meta'].get('load_s', 0):.2f} "
              f"diff {s.get('vs_breeze', {}).get('char_diff_rate', 0):.3f} same {s.get('vs_breeze', {}).get('identical', '-')} "
              f"punct {s['punct']['rows_with_any']}/{s['punct']['rows_with_sentence_end']} "
              f"en {s['english']['words']} footprint {s['meta'].get('peak_footprint', 0) / 1e9:.2f}GB")


def convdiff(results_path, out_path):
    """簡轉繁的模型:逐字轉回簡體對齊原生繁體模型,簡體相同、繁體不同的字列出來。"""
    import difflib
    results = json.load(open(results_path, encoding="utf-8"))
    refs = [n for n, m in results["models"].items() if m["meta"]["native_traditional"]]
    chars = sorted({c for m in results["models"].values() for r in m["rows"].values() for c in r["text"] if HAN.match(c)})
    to_simp = dict(zip(chars, opencc(chars, "t2s")))  # 逐字轉簡體(不用詞組)
    out = {}
    for name, m in results["models"].items():
        if m["meta"]["native_traditional"]:
            continue
        pairs = []
        for item_id, row in m["rows"].items():
            hyp = [c for c in row["text"] if HAN.match(c)]
            for ref_name in refs:
                ref = [c for c in results["models"][ref_name]["rows"][item_id]["text"] if HAN.match(c)]
                if not hyp or not ref:
                    continue
                sm = difflib.SequenceMatcher(a=[to_simp[c] for c in hyp], b=[to_simp[c] for c in ref], autojunk=False)
                for tag, a0, a1, b0, b1 in sm.get_opcodes():
                    if tag != "equal":
                        continue
                    for k in range(a1 - a0):
                        if hyp[a0 + k] != ref[b0 + k]:
                            ctx = "".join(hyp[max(0, a0 + k - 4):a0 + k + 5])
                            pairs.append({"id": item_id, "ref_model": ref_name, "hyp": hyp[a0 + k],
                                          "ref": ref[b0 + k], "context": ctx})
        out[name] = pairs
        summary = {}
        for p in pairs:
            key = f"{p['hyp']}/{p['ref']}"
            summary[key] = summary.get(key, 0) + 1
        print(name, len(pairs), sorted(summary.items(), key=lambda kv: -kv[1])[:20])
    json.dump(out, open(out_path, "w", encoding="utf-8"), ensure_ascii=False, indent=1)


def blind(results_path, blinded_path, key_path, seed=20261022):
    results = json.load(open(results_path, encoding="utf-8"))
    rng = random.Random(seed)
    durations = results["durations"]
    blinded, key = [], {}
    n = 0
    for item_id in durations:
        versions = {}
        for name, m in results["models"].items():
            text = strip_punct(m["rows"][item_id]["text"])
            versions.setdefault(text, []).append(name)
        if len(versions) < 2:
            continue
        n += 1
        texts = list(versions)
        rng.shuffle(texts)
        labels = [chr(ord("A") + k) for k in range(len(texts))]
        blinded.append({"item": n, "seconds": round(durations[item_id], 1),
                        "versions": dict(zip(labels, texts))})
        key[str(n)] = {"id": item_id, "labels": {lab: versions[t] for lab, t in zip(labels, texts)}}
    json.dump(blinded, open(blinded_path, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    json.dump(key, open(key_path, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print(f"{n} 題(其餘各模型完全相同)")


def unblind(results_path, key_path, review_path, out_path):
    results = json.load(open(results_path, encoding="utf-8"))
    key = json.load(open(key_path, encoding="utf-8"))
    review = {str(r["item"]): r for r in json.load(open(review_path, encoding="utf-8"))}
    durations = results["durations"]
    names = list(results["models"])
    tally = {n: {g: {"ok": 0, "minor": 0, "wrong": 0, "best": 0} for g in ("short", "mid", "long", "all")}
             for n in names}
    per_item = []
    for item, k in key.items():
        r = review.get(item)
        if r is None:
            continue
        g = group_of(durations[k["id"]])
        row = {"item": int(item), "id": k["id"], "group": g, "models": {}}
        for label, models in k["labels"].items():
            verdict = r["verdicts"][label]
            best = label in r["best"]
            for name in models:
                row["models"][name] = {"verdict": verdict, "best": best}
                for gg in (g, "all"):
                    tally[name][gg][verdict] += 1
                    tally[name][gg]["best"] += best
        per_item.append(row)
    json.dump({"tally": tally, "items": per_item}, open(out_path, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    for name in names:
        t = tally[name]["all"]
        print(f"{name:12s} ok {t['ok']:3d} minor {t['minor']:3d} wrong {t['wrong']:3d} best {t['best']:3d}")


if __name__ == "__main__":
    cmd, args = sys.argv[1], sys.argv[2:]
    {"collect": collect, "combine": combine, "stats": stats, "convdiff": convdiff, "blind": blind,
     "unblind": unblind}[cmd](*args)
