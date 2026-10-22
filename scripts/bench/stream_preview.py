#!/usr/bin/env python3
"""邊講邊出字的調查:挑錄音、記 GPU 使用率、整理 tc_stream_sim 的結果。

設計見 docs/investigations/2026-10-22-streaming-preview.md。

用法:
  stream_preview.py lists <錄音資料夾> <輸出資料夾>      寫 prefix.tsv、loop.tsv
  stream_preview.py gpu-sample <輸出.tsv>                 每 0.5 秒記一次 GPU 使用率(ioreg,不用 sudo),直到被停掉
  stream_preview.py analyze <原始輸出資料夾> <stats.json> [<detail.json>]

stats.json 只有數字(可以放公開文件);detail.json 含辨識文字(只放私人 repo)。
"""

import glob
import json
import os
import re
import statistics
import subprocess
import sys
import time
import wave

PUA = re.compile("[-]")
PUNCT = re.compile(r"[\s,.!?;:、,。!?;:「」『』()()…—\-\"'“”‘’]")


def duration(path):
    with wave.open(path) as w:
        return w.getnframes() / w.getframerate()


def cmd_lists(rec_dir, out_dir):
    items = sorted(
        ((duration(p), os.path.splitext(os.path.basename(p))[0], p) for p in glob.glob(os.path.join(rec_dir, "*.wav"))),
        reverse=True,
    )
    long_ = [i for i in items if i[0] >= 30]
    medium = [i for i in items if 10 <= i[0] < 20]
    short = [i for i in items if 3 <= i[0] < 5]

    def spread(xs, k):
        if len(xs) <= k:
            return xs
        return [xs[round(j * (len(xs) - 1) / (k - 1))] for j in range(k)]

    prefix = long_  # 30 秒以上的都量前 2–30 秒;60 秒以上的另外量前 60 秒
    loop = spread(long_, 5) + spread(medium, 4) + spread(short, 4)
    os.makedirs(out_dir, exist_ok=True)
    for name, xs in (("prefix.tsv", prefix), ("loop.tsv", loop)):
        with open(os.path.join(out_dir, name), "w") as f:
            for d, i, p in xs:
                f.write(f"{i}\t{p}\n")
        print(name, len(xs), "段,合計 %.0f 秒" % sum(d for d, _, _ in xs), [round(d, 1) for d, _, _ in xs])


def cmd_gpu_sample(out_path):
    """每 0.5 秒記 GPU 使用率;每 2 秒另外記名稱含 speech 的系統行程記憶體(Apple 的辨識在系統行程裡跑)。"""
    pat = re.compile(r'"Device Utilization %"=(\d+)')
    speech_path = out_path.replace("gpu-", "speechproc-")
    k = 0
    with open(out_path, "a") as f, open(speech_path, "a") as g:
        while True:
            t = time.time()
            out = subprocess.run(
                ["/usr/sbin/ioreg", "-r", "-d", "1", "-c", "IOAccelerator"], capture_output=True, text=True
            ).stdout
            m = pat.search(out)
            if m:
                f.write(f"{t:.3f}\t{m.group(1)}\n")
                f.flush()
            if k % 4 == 0:
                ps = subprocess.run(["/bin/ps", "-axo", "rss=,pcpu=,comm="], capture_output=True, text=True).stdout
                for line in ps.splitlines():
                    parts = line.split(None, 2)
                    if len(parts) == 3 and "speech" in parts[2].lower():
                        g.write(f"{t:.3f}\t{parts[0]}\t{parts[1]}\t{os.path.basename(parts[2])}\n")
                g.flush()
            k += 1
            time.sleep(max(0.0, 0.5 - (time.time() - t)))


def read_jsonl(path):
    with open(path) as f:
        return [json.loads(line) for line in f if line.strip()]


def clean(s):
    return PUA.sub("", s)


def bare(s):
    return PUNCT.sub("", clean(s))


def lcp(a, b):
    n = min(len(a), len(b))
    i = 0
    while i < n and a[i] == b[i]:
        i += 1
    return i


def edit_distance(a, b):
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


def q(xs, p):
    xs = sorted(xs)
    if not xs:
        return None
    k = (len(xs) - 1) * p
    lo = int(k)
    hi = min(lo + 1, len(xs) - 1)
    return round(xs[lo] + (xs[hi] - xs[lo]) * (k - lo), 3)


def summary(xs):
    if not xs:
        return None
    return {"n": len(xs), "median": q(xs, 0.5), "p90": q(xs, 0.9), "max": round(max(xs), 3)}


def peak_footprint(path):
    try:
        text = open(path).read()
    except OSError:
        return None
    m = re.search(r"(\d+)\s+peak memory footprint", text)
    return round(int(m.group(1)) / 1e9, 2) if m else None


def gpu_util(samples, start, end):
    xs = [u for t, u in samples if start <= t <= end]
    return round(statistics.mean(xs), 1) if xs else None


def analyze_prefix(rows):
    by_len = {}
    fails = {}
    for r in rows:
        if r.get("warmup"):
            continue
        L = int(r["a"])
        if not r["ok"]:
            fails[L] = fails.get(L, 0) + 1
            continue
        by_len.setdefault(L, {}).setdefault(r["id"], []).append(r)
    out = {}
    for L, per_id in sorted(by_len.items()):
        wall = [statistics.median(x["wall_ms"] for x in rs) / 1000 for rs in per_id.values()]
        enc = [statistics.median(x["encode_ms"] for x in rs) / 1000 for rs in per_id.values()]
        dec = [statistics.median(x["decode_ms"] for x in rs) / 1000 for rs in per_id.values()]
        chars = [statistics.median(len(bare(x["text"])) for x in rs) for rs in per_id.values()]
        same = sum(1 for rs in per_id.values() if len({x["text"] for x in rs}) == 1)
        out[str(L)] = {
            "recordings": len(per_id),
            "wall_s": summary(wall),
            "encode_s_median": q(enc, 0.5),
            "decode_s_median": q(dec, 0.5),
            "chars_median": q(chars, 0.5),
            "repeats_identical": f"{same}/{len(per_id)}",
            "fails": fails.get(L, 0),
        }
    return out


def analyze_loop(rows, samples):
    """一個變體(window)的結果。回傳 (統計, 每段的明細含文字)。"""
    by_id = {}
    for r in rows:
        if r.get("warmup"):
            continue
        by_id.setdefault(r["id"], []).append(r)
    stats_rows = []
    detail = []
    for rid, rs in by_id.items():
        summ = next(r for r in rs if r["kind"] == "summary")
        final = next(r for r in rs if r["kind"] == "final")
        updates = [r for r in rs if r["kind"] in ("pass", "commit")]
        dur = summ["duration"]
        # 面板上顯示的文字:已定稿的各段 + 目前這一段最新的辨識結果
        committed = ""
        displays = []
        for r in updates:
            if r["kind"] == "commit":
                committed += clean(r["text"])
                displays.append((r["b"], r["win_end"], committed, r))
            else:
                displays.append((r["b"], r["win_end"], committed + clean(r["text"]), r))
        rewrites = []
        prev = ""
        for _, _, d, _ in displays:
            rewrites.append(len(prev) - lcp(prev, d))
            prev = d
        lags = [b - win_end for b, win_end, _, _ in displays]
        gaps = [displays[k][0] - displays[k - 1][0] for k in range(1, len(displays))]
        last_display = displays[-1][2] if displays else ""
        f = bare(final["text"])
        diff = edit_distance(bare(last_display), f) / max(1, len(f)) if displays else None
        stats_rows.append({
            "id": rid,
            "duration": dur,
            "updates": len(displays),
            "first_text_at": displays[0][0] if displays else None,
            "lags": lags,
            "gaps": gaps,
            "pass_s": [(r["win_end"] - r["win_start"], r["wall_ms"] / 1000) for r in updates],
            "rewrites": rewrites,
            "busy_frac": summ["busy_s"] / dur,
            "wait_after_stop_s": summ["wait_after_stop_s"],
            "final_s": final["wall_ms"] / 1000,
            "final_ok": final["ok"],
            "last_preview_vs_final": diff,
            "gpu_util": gpu_util(samples, summ["epoch_start"], summ["epoch_end"]),
            "final_text": final["text"],
        })
        detail.append({
            "id": rid,
            "duration": dur,
            "updates": [
                {"kind": r["kind"], "t_end": r["b"], "win": [r["win_start"], r["win_end"]], "s": r["wall_ms"] / 1000,
                 "display": d}
                for _, _, d, r in displays
            ],
            "final": clean(final["text"]),
            "wait_after_stop_s": summ["wait_after_stop_s"],
        })
    return stats_rows, detail


def simplified_only_chars():
    """App 用的簡體專用字表(VoiceInk/Features/ZhTW/ZhTWSimplifiedOnly.swift),每兩個字一組。"""
    here = os.path.dirname(os.path.abspath(__file__))
    path = os.path.join(here, "..", "..", "VoiceInk", "Features", "ZhTW", "ZhTWSimplifiedOnly.swift")
    m = re.search(r'pairs = "([^"]*)"', open(path, encoding="utf-8").read())
    pairs = m.group(1)
    return set(pairs[0::2])


def analyze_apple(rows, samples, tea_final_by_id):
    """macOS SpeechTranscriber(zh-TW):volatile 是中途的猜測,final 是定稿;面板顯示 = 各段定稿 + 最新的 volatile。"""
    simp = simplified_only_chars()
    by_id = {}
    for r in rows:
        by_id.setdefault(r["id"], []).append(r)
    stats_rows, detail = [], []
    for rid, rs in by_id.items():
        summ = next((r for r in rs if r["kind"] == "summary"), None)
        if summ is None:
            continue
        results = sorted((r for r in rs if r["kind"] in ("volatile", "final")), key=lambda r: r["t"])
        finals = ""
        displays = []
        for r in results:
            if r["kind"] == "final":
                finals += r["text"]
                displays.append((r["t"], r["range_end"], finals))
            else:
                displays.append((r["t"], r["range_end"], finals + r["text"]))
        # 只看錄音期間(錄音結束後的 finalize 不算即時顯示)
        live = [d for d in displays if d[0] <= summ["duration"] + 0.05]
        rewrites, prev = [], ""
        for _, _, d in live:
            rewrites.append(len(prev) - lcp(prev, d))
            prev = d
        tea = bare(tea_final_by_id.get(rid, ""))
        apple_final = bare(finals)
        last_live = bare(live[-1][2]) if live else ""
        stats_rows.append({
            "id": rid,
            "duration": summ["duration"],
            "updates": len(live),
            "first_text_at": live[0][0] if live else None,
            "lags": [t - end for t, end, _ in live],
            "gaps": [live[k][0] - live[k - 1][0] for k in range(1, len(live))],
            "rewrites": rewrites,
            "setup_s": summ["setup_s"],
            "finalize_wait_s": summ["finalize_wait_s"],
            "live_vs_tea_final": edit_distance(last_live, tea) / max(1, len(tea)) if tea else None,
            "apple_final_vs_tea_final": edit_distance(apple_final, tea) / max(1, len(tea)) if tea else None,
            "simplified_chars": sum(1 for c in finals if c in simp),
            "chars": len(apple_final),
            "punct_chars": len(finals) - len(apple_final) - finals.count(" "),
            "gpu_util": gpu_util(samples, summ["epoch_start"], summ["epoch_end"]),
        })
        detail.append({"id": rid, "duration": summ["duration"],
                       "updates": [{"t": t, "range_end": e, "display": d} for t, e, d in displays],
                       "final": finals})
    out = {}
    groups = {"all": stats_rows}
    for r in stats_rows:
        groups.setdefault(bucket(r["duration"]), []).append(r)
    for g, rs in groups.items():
        rewrites = [x for r in rs for x in r["rewrites"][1:]]
        rewritten = [x for x in rewrites if x > 0]
        out[g] = {
            "recordings": len(rs),
            "updates_per_recording": summary([r["updates"] for r in rs]),
            "first_text_at_s": summary([r["first_text_at"] for r in rs if r["first_text_at"] is not None]),
            "update_gap_s": summary([x for r in rs for x in r["gaps"]]),
            "lag_s": summary([x for r in rs for x in r["lags"]]),
            "setup_s": summary([r["setup_s"] for r in rs]),
            "finalize_wait_s": summary([r["finalize_wait_s"] for r in rs]),
            "rewrite_updates": f"{len(rewritten)}/{len(rewrites)}",
            "rewrite_chars": summary(rewritten),
            "live_vs_tea_final_diff": summary([r["live_vs_tea_final"] for r in rs if r["live_vs_tea_final"] is not None]),
            "apple_final_vs_tea_final_diff": summary([r["apple_final_vs_tea_final"] for r in rs
                                                      if r["apple_final_vs_tea_final"] is not None]),
            "simplified_chars": sum(r["simplified_chars"] for r in rs),
            "chars": sum(r["chars"] for r in rs),
            "punct_per_100_chars": round(100 * sum(r["punct_chars"] for r in rs) / max(1, sum(r["chars"] for r in rs)), 1),
            "gpu_util_pct": summary([r["gpu_util"] for r in rs if r["gpu_util"] is not None]),
        }
    return out, detail


def bucket(dur):
    return "short" if dur < 5 else "medium" if dur < 20 else "long"


def loop_stats(stats_rows, base_by_id):
    out = {}
    groups = {"all": stats_rows}
    for r in stats_rows:
        groups.setdefault(bucket(r["duration"]), []).append(r)
    for g, rs in groups.items():
        pass_s = [s for r in rs for _, s in r["pass_s"]]
        win_s = [w for r in rs for w, _ in r["pass_s"]]
        rewrites = [x for r in rs for x in r["rewrites"][1:]]
        rewritten = [x for x in rewrites if x > 0]
        extra = [r["wait_after_stop_s"] - base_by_id[r["id"]]["wait_after_stop_s"]
                 for r in rs if r["id"] in base_by_id]
        out[g] = {
            "recordings": len(rs),
            "audio_s": round(sum(r["duration"] for r in rs), 1),
            "updates_per_recording": summary([r["updates"] for r in rs]),
            "first_text_at_s": summary([r["first_text_at"] for r in rs if r["first_text_at"] is not None]),
            "update_gap_s": summary([x for r in rs for x in r["gaps"]]),
            "lag_s": summary([x for r in rs for x in r["lags"]]),
            "pass_s": summary(pass_s),
            "pass_window_s": summary(win_s),
            "busy_frac": summary([r["busy_frac"] for r in rs]),
            "gpu_util_pct": summary([r["gpu_util"] for r in rs if r["gpu_util"] is not None]),
            "rewrite_updates": f"{len(rewritten)}/{len(rewrites)}",
            "rewrite_chars": summary(rewritten),
            "wait_after_stop_s": summary([r["wait_after_stop_s"] for r in rs]),
            "extra_wait_vs_baseline_s": summary(extra),
            "last_preview_vs_final_diff": summary([r["last_preview_vs_final"] for r in rs
                                                   if r["last_preview_vs_final"] is not None]),
            "final_ok": sum(1 for r in rs if r["final_ok"]),
        }
    return out


def cmd_analyze(raw_dir, stats_path, detail_path=None):
    samples = []
    for p in glob.glob(os.path.join(raw_dir, "gpu-*.tsv")):
        with open(p) as f:
            for line in f:
                t, u = line.split("\t")
                samples.append((float(t), int(u)))
    speech = []  # (時間, 名稱, RSS MB, CPU%)
    for p in glob.glob(os.path.join(raw_dir, "speechproc-*.tsv")):
        with open(p) as f:
            for line in f:
                t, rss, cpu, name = line.rstrip("\n").split("\t")
                speech.append((float(t), name, int(rss) / 1024, float(cpu)))
    stats = {"prefix": None, "loop": {}, "memory_gb": {}, "gpu_idle_pct": None}
    detail = {"loop": {}}
    idle = os.path.join(raw_dir, "idle-window.json")
    if os.path.exists(idle):
        w = json.load(open(idle))
        stats["gpu_idle_pct"] = gpu_util(samples, w["start"], w["end"])
    p = os.path.join(raw_dir, "prefix.jsonl")
    if os.path.exists(p):
        stats["prefix"] = analyze_prefix(read_jsonl(p))
        stats["memory_gb"]["prefix"] = peak_footprint(os.path.join(raw_dir, "prefix.time.txt"))
    variants = {}
    for p in sorted(glob.glob(os.path.join(raw_dir, "loop-w*.jsonl"))):
        name = os.path.basename(p)[len("loop-"):-len(".jsonl")]
        variants[name] = analyze_loop(read_jsonl(p), samples)
        stats["memory_gb"][name] = peak_footprint(os.path.join(raw_dir, f"loop-{name}.time.txt"))
    base = {r["id"]: r for r in variants.get("w0", ([], []))[0]}
    finals = {}
    for name, (rows, det) in variants.items():
        stats["loop"][name] = loop_stats(rows, base)
        detail["loop"][name] = det
        for r in rows:
            finals.setdefault(r["id"], {})[name] = r["final_text"]
    p = os.path.join(raw_dir, "apple.jsonl")
    if os.path.exists(p):
        tea_final = {r["id"]: r["final_text"] for r in variants.get("w0", ([], []))[0]}
        stats["apple"], detail["apple"] = analyze_apple(read_jsonl(p), samples, tea_final)
        stats["memory_gb"]["apple"] = peak_footprint(os.path.join(raw_dir, "apple.time.txt"))
        # Apple 的辨識在系統行程裡跑:Apple 那輪期間各個 speech 行程的最大記憶體和 CPU,和閒置時比
        sums = [r for r in read_jsonl(p) if r["kind"] == "summary"]
        if sums and speech:
            a0, a1 = min(r["epoch_start"] for r in sums), max(r["epoch_end"] for r in sums)
            w = json.load(open(idle)) if os.path.exists(idle) else {"start": 0, "end": 0}
            names = sorted({n for _, n, _, _ in speech})
            stats["apple_system_processes"] = {
                n: {
                    "idle_rss_mb_max": max([r for t, m, r, _ in speech if m == n and w["start"] <= t <= w["end"]], default=None),
                    "run_rss_mb_max": max([r for t, m, r, _ in speech if m == n and a0 <= t <= a1], default=None),
                    "run_cpu_pct_mean": round(statistics.mean([c for t, m, _, c in speech if m == n and a0 <= t <= a1] or [0]), 1),
                }
                for n in names
            }
    # 貼出去的文字:有沒有顯示都應該一樣(同一個模型、同一段錄音、同樣切段)
    same = sum(1 for v in finals.values() if len(set(v.values())) == 1)
    stats["final_identical_across_variants"] = f"{same}/{len(finals)}"
    with open(stats_path, "w") as f:
        json.dump(stats, f, ensure_ascii=False, indent=1)
    if detail_path:
        with open(detail_path, "w") as f:
            json.dump(detail, f, ensure_ascii=False, indent=1)
    print(json.dumps(stats, ensure_ascii=False, indent=1))


def main():
    if len(sys.argv) >= 4 and sys.argv[1] == "lists":
        cmd_lists(sys.argv[2], sys.argv[3])
    elif len(sys.argv) == 3 and sys.argv[1] == "gpu-sample":
        cmd_gpu_sample(sys.argv[2])
    elif len(sys.argv) >= 4 and sys.argv[1] == "analyze":
        cmd_analyze(sys.argv[2], sys.argv[3], sys.argv[4] if len(sys.argv) > 4 else None)
    else:
        print(__doc__)
        sys.exit(2)


if __name__ == "__main__":
    main()
