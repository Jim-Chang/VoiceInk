#!/usr/bin/env python3
"""TEA 詞彙表的量測:整理 tea_vocab_run.sh 的輸出,找出兩組結果不同的地方、統計時間和記憶體。

做法見 docs/plan/2026-10-22-tea-vocabulary.md。只讀參數給的路徑;實際聽寫的內容只寫進參數給的輸出檔
(放私人 repo),stdout 只印統計數字。

  list <history.json> <list.tsv>
      聽寫紀錄 → tc_bench 的清單(id<TAB>wav 的絕對路徑)。
  clean-input <輸出資料夾> <rows.json>
      各組第一輪的辨識結果 → punct-ct.sh 的輸入([{"id": "組|錄音 id", "text", "model"}]),
      punct-ct 會照 App 的流程跑 ZhTWTranscript.clean,結果在 "cleaned"。
  report <history.json> <輸出資料夾> <terms.txt> <terms-large.txt> <report.json> <spots.json> [--cleaned 檔案]
      比較 A→B、B→C、B→C2:逐字相同的比例、每一處差異(含前後文、涉及哪些清單詞)、
      清單詞次數的變化、時間、記憶體。沒給 --cleaned 時只刪私用區字元(測試工具用)。
"""
import difflib
import glob
import json
import os
import re
import statistics
import sys
import unicodedata

ARMS = ["A", "B", "C", "C2"]
PAIRS = [("A", "B"), ("B", "C"), ("B", "C2")]
MODEL_NAME = "tea-asr-1.1"
WORD = re.compile(r"[a-z0-9]+(?:[.+#_'-][a-z0-9]+)*[+#]*")


def tokens(text):
    """比對單位:英文、數字連在一起的算一個(可以含 . + # _ ' -),其他字一個字一個;去掉標點、空白。"""
    text = unicodedata.normalize("NFKC", text).lower()
    out, i = [], 0
    while i < len(text):
        m = WORD.match(text, i)
        if m:
            out.append(m.group())
            i = m.end()
            continue
        ch = text[i]
        i += 1
        if ch.isspace() or unicodedata.category(ch)[0] in "PSZC":
            continue
        out.append(ch)
    return out


def join(toks):
    """tokens 接回文字:兩個英文、數字單位之間補空格。"""
    out = []
    for k, t in enumerate(toks):
        if k and WORD.fullmatch(t) and WORD.fullmatch(toks[k - 1]):
            out.append(" ")
        out.append(t)
    return "".join(out)


def strip_pua(text):
    return "".join(ch for ch in text if not 0xE000 <= ord(ch) <= 0xF8FF)


def load_terms(path):
    terms = [line.strip() for line in open(path, encoding="utf-8") if line.strip()]
    return [(t, tokens(t)) for t in terms]


def occurrences(toks, terms):
    """不重疊、長的優先;回傳 [(詞, 起, 迄)]。"""
    found, used = [], [False] * len(toks)
    for term, tt in sorted(terms, key=lambda x: -len(x[1])):
        n = len(tt)
        if n == 0:
            continue
        for i in range(len(toks) - n + 1):
            if toks[i:i + n] == tt and not any(used[i:i + n]):
                found.append((term, i, i + n))
                for k in range(i, i + n):
                    used[k] = True
    return sorted(found, key=lambda x: x[1])


def read_runs(out_dir):
    runs = {}
    for path in sorted(glob.glob(os.path.join(out_dir, "run*", "*.jsonl"))):
        rnd = os.path.basename(os.path.dirname(path))
        arm = os.path.basename(path)[:-len(".jsonl")]
        rows = [json.loads(line) for line in open(path, encoding="utf-8") if line.strip()]
        runs.setdefault(arm, {})[rnd] = {r["id"]: r for r in rows if not r.get("warmup")}
    return runs


def read_time(path):
    if not os.path.exists(path):
        return None
    text = open(path, encoding="utf-8", errors="replace").read()
    out = {}
    for key, pat in (("max_rss", r"(\d+)\s+maximum resident set size"), ("peak_footprint", r"(\d+)\s+peak memory footprint")):
        m = re.search(pat, text)
        if m:
            out[key] = int(m.group(1))
    return out


def merge_opcodes(ops, gap=1):
    """把中間只隔 gap 個相同單位的差異併成一處。"""
    spots = []
    for tag, i1, i2, j1, j2 in ops:
        if tag == "equal":
            continue
        if spots and i1 - spots[-1][1] <= gap and j1 - spots[-1][3] <= gap:
            spots[-1] = (spots[-1][0], i2, spots[-1][2], j2)
        else:
            spots.append((i1, i2, j1, j2))
    return spots


def cmd_list(history, out):
    base = os.path.dirname(os.path.abspath(history))
    items = json.load(open(history, encoding="utf-8"))
    with open(out, "w", encoding="utf-8") as f:
        for it in items:
            f.write(f"{it['id']}\t{os.path.normpath(os.path.join(base, it['recording']))}\n")
    print(f"{len(items)} recordings")


def cmd_clean_input(out_dir, out):
    runs = read_runs(out_dir)
    rows = []
    for arm in ARMS:
        first = runs.get(arm, {}).get("run1", {})
        rows += [{"id": f"{arm}|{cid}", "text": r["text"], "model": MODEL_NAME} for cid, r in first.items()]
    json.dump(rows, open(out, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print(f"{len(rows)} rows")


def cmd_report(history, out_dir, terms_path, large_path, report_path, spots_path, cleaned_path=None):
    items = {it["id"]: it for it in json.load(open(history, encoding="utf-8"))}
    runs = read_runs(out_dir)
    cleaned = {}
    if cleaned_path:
        for r in json.load(open(cleaned_path, encoding="utf-8")):
            cleaned[r["id"]] = r["cleaned"]
    terms, large = load_terms(terms_path), load_terms(large_path)
    report = {"clean": "app" if cleaned_path else "pua-only", "arms": {}, "pairs": {}}

    def text(arm, cid):
        if cleaned_path:
            return cleaned[f"{arm}|{cid}"]
        return strip_pua(runs[arm]["run1"][cid]["text"])

    for arm, by_round in runs.items():
        first = by_round.get("run1", {})
        stable = sum(all(r.get(cid, {}).get("text") == row["text"] for r in by_round.values()) for cid, row in first.items())
        best = {cid: min(r[cid]["wall_ms"] for r in by_round.values() if cid in r) for cid in first}
        short = [best[c] for c in first if items.get(c, {}).get("duration", first[c]["duration"]) < 5]
        report["arms"][arm] = {
            "rounds": len(by_round),
            "clips": len(first),
            "failed": sum(not r["ok"] for r in first.values()),
            "failed_status": sorted({r["status"] for r in first.values() if not r["ok"]}),
            "same_text_all_rounds": stable,
            "median_ms_short": round(statistics.median(short), 1) if short else None,
            "median_ms_all": round(statistics.median(best.values()), 1) if best else None,
            "memory": {rnd: read_time(os.path.join(out_dir, rnd, f"{arm}.time.txt")) for rnd in by_round},
        }

    all_spots = []
    for old, new in PAIRS:
        if old not in runs or new not in runs:
            continue
        lst = large if new == "C2" else terms
        ids = [c for c in runs[old]["run1"] if c in runs[new]["run1"]]
        identical, n_spots, n_term_spots, dumps = 0, 0, 0, []
        count_old, count_new = {}, {}
        for cid in ids:
            to, tn = tokens(text(old, cid)), tokens(text(new, cid))
            oo, on = occurrences(to, lst), occurrences(tn, lst)
            for t, *_ in oo:
                count_old[t] = count_old.get(t, 0) + 1
            for t, *_ in on:
                count_new[t] = count_new.get(t, 0) + 1
            gained = {}
            for t, *_ in on:
                gained[t] = gained.get(t, 0) + 1
            for t, *_ in oo:
                gained[t] = gained.get(t, 0) - 1
            newly = sum(v for v in gained.values() if v > 0)
            if newly >= 3:
                dumps.append(cid)
            if to == tn:
                identical += 1
                continue
            for i1, i2, j1, j2 in merge_opcodes(difflib.SequenceMatcher(None, to, tn, autojunk=False).get_opcodes()):
                involved = sorted({t for t, a, b in oo if a < i2 and b > i1} | {t for t, a, b in on if a < j2 and b > j1})
                n_spots += 1
                n_term_spots += bool(involved)
                all_spots.append({
                    "pair": f"{old}>{new}", "id": cid, "duration": items.get(cid, {}).get("duration"),
                    "old": join(to[i1:i2]), "new": join(tn[j1:j2]),
                    "before": join(to[max(0, i1 - 8):i1]), "after": join(to[i2:i2 + 8]),
                    "terms": involved,
                    # 整段文字,這一處用 ⟦ ⟧ 標出來(tea_vocab_page.py 用)
                    "old_marked": join(to[:i1]) + "⟦" + join(to[i1:i2]) + "⟧" + join(to[i2:]),
                    "new_marked": join(tn[:j1]) + "⟦" + join(tn[j1:j2]) + "⟧" + join(tn[j2:]),
                })
        report["pairs"][f"{old}>{new}"] = {
            "clips": len(ids), "identical": identical, "spots": n_spots, "spots_with_terms": n_term_spots,
            "clips_gaining_3plus_terms": len(dumps),
            "term_occurrences_old": sum(count_old.values()), "term_occurrences_new": sum(count_new.values()),
            "terms_changed": {t: [count_old.get(t, 0), count_new.get(t, 0)]
                              for t in sorted(set(count_old) | set(count_new)) if count_old.get(t, 0) != count_new.get(t, 0)},
        }
    json.dump(report, open(report_path, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    json.dump(all_spots, open(spots_path, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    for arm, a in report["arms"].items():
        print(f"{arm}: clips {a['clips']}, failed {a['failed']}, same text all rounds {a['same_text_all_rounds']}, "
              f"median short {a['median_ms_short']} ms, all {a['median_ms_all']} ms")
    for pair, p in report["pairs"].items():
        print(f"{pair}: identical {p['identical']}/{p['clips']}, spots {p['spots']} (with terms {p['spots_with_terms']}), "
              f"clips gaining >=3 terms {p['clips_gaining_3plus_terms']}, term occurrences {p['term_occurrences_old']} -> {p['term_occurrences_new']}")


def main(argv):
    if len(argv) >= 3 and argv[0] == "list":
        cmd_list(argv[1], argv[2])
    elif len(argv) >= 3 and argv[0] == "clean-input":
        cmd_clean_input(argv[1], argv[2])
    elif len(argv) >= 7 and argv[0] == "report":
        cleaned = argv[argv.index("--cleaned") + 1] if "--cleaned" in argv else None
        cmd_report(*argv[1:7], cleaned_path=cleaned)
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv[1:])
