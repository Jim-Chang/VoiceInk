#!/usr/bin/env python3
"""把 VoiceInk 的系統紀錄整理成「每次聽寫一行」的計時表。只讀時間和數量,不讀內容。

用法:
  python3 -I scripts/timing_report.py                       # 最近 2 小時
  python3 -I scripts/timing_report.py --last 30m
  python3 -I scripts/timing_report.py --start "2026-10-21 17:00:00"
  python3 -I scripts/timing_report.py --load load.tsv       # 加上 scripts/bench/sample_load.py 的負載紀錄

欄位(秒):
  rec      錄音長度(按下快捷鍵到放開)
  gap      距離上一次貼上
  asr      語音辨識
  punct    辨識完直接補標點(CT-Transformer,ZhTWPunctuator);後面 pre 到 xpc 是舊的 AI 潤稿補標點(Breeze2)
  pre      辨識完到開始補標點(字詞替換等)
  chunks   長的逐字稿分成幾段補標點(其他補標點欄位是各段加總)
  queue    等前一個補標點動作做完
  idle     補標點模型距離上次工作的閒置時間;warm=0 表示這次要重新載入
  pfx      1 = 用了 prefix cache(固定的指示和範例沒有重讀)
  prep     補標點前確認模型已載入
  prompt   讀入指示和逐字稿(token 數/秒數)
  gen      產生文字(token 數/秒數)
  other    引擎裡其他時間(套用對話範本等)
  xpc      App 送出到收到 XPC 回覆
  paste    補標點完到貼上
  total    放開快捷鍵到貼上
  bgGPU    錄音期間 GPU 平均使用率(有 --load 時)
  bgTop    錄音期間最吃 CPU 的程序(有 --load 時,不含 VoiceInk)
"""
import argparse
import json
import re
import subprocess
from datetime import datetime, timedelta

SUBSYSTEM = "com.prakashjoshipax.voiceink"
FIELDS = re.compile(r"(\w+)=(\S+)")


def read_events(args):
    command = [
        "/usr/bin/log", "show", "--style", "ndjson",
        "--predicate", f'subsystem == "{SUBSYSTEM}"',
    ]
    command += ["--start", args.start] if args.start else ["--last", args.last]
    out = subprocess.run(command, capture_output=True, text=True).stdout
    events = []
    for line in out.splitlines():
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue
        if "eventMessage" not in entry:
            continue
        stamp = datetime.strptime(entry["timestamp"], "%Y-%m-%d %H:%M:%S.%f%z")
        events.append((stamp, entry.get("category", ""), entry["eventMessage"]))
    events.sort(key=lambda e: e[0])
    return events


def group_dictations(events):
    """每次開始辨識算一次聽寫。

    - 錄音開始 = 之前最近一次顯示錄音面板。螢幕變動時重新擺放面板也會記一次「Showed」,不算。
    - 準備模型(*-prepare)發生在錄音開始時、CT 模型載入(punct-load)發生在 App 啟動時,都算下一次聽寫的;
      補標點和貼上算目前這次的。
    - 沒講話的錄音只有辨識、沒有補標點和貼上,照樣一行。
    """
    dictations = []
    current = None
    upcoming = {}
    previous_recorder_message = ""
    for stamp, category, message in events:
        if category == "RecorderUIManager":
            if message.startswith("Showed recorder panel") and not previous_recorder_message.startswith("Repositioning"):
                upcoming = {"rec_start": stamp}
            previous_recorder_message = message
            continue
        if message.startswith("Initiating local transcription"):
            current = {"rec_start": None, **upcoming, "asr_start": stamp}
            upcoming = {}
            dictations.append(current)
        elif category == "ZhTWTiming":
            name = message.split(" ", 1)[0]
            target = upcoming if name.endswith("-prepare") or name == "punct-load" else current
            if target is None:
                continue
            values = dict(FIELDS.findall(message))
            values["_at"] = stamp
            target[name] = values
            # 長的逐字稿分段補標點,每段各一筆
            target.setdefault(name + "[]", []).append(values)
        elif current is None:
            continue
        elif message.startswith("Whisper transcription completed"):
            current.setdefault("asr_end", stamp)
        elif category == "CursorPaster" and message.startswith("Paste id="):
            current.setdefault("paste", stamp)
    return dictations


def read_load(path):
    samples = []
    with open(path, encoding="utf-8") as f:
        next(f)
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if len(parts) < 2:
                continue
            samples.append((parts[0], int(parts[1]), parts[2] if len(parts) > 2 else ""))
    return samples


def seconds(a, b):
    return (b - a).total_seconds() if a and b else None


def fmt(value, width=5):
    if value is None or value == "-":
        return "-".rjust(width)
    if isinstance(value, str):
        return value.rjust(width)
    return f"{value:.2f}".rjust(width)


def number(values, key):
    try:
        return float(values[key])
    except (KeyError, ValueError, TypeError):
        return None


def combined(d, name):
    """把分段的計時加總;warm/idle/thermal/qos/prefix 用第一段的"""
    parts = d.get(name + "[]", [])
    if not parts:
        return {}
    out = dict(parts[0])
    for key in ("queue", "xpc", "prepare", "encode", "prompt", "generate", "total",
                "promptTokens", "outputTokens"):
        values = [number(part, key) for part in parts]
        if all(v is not None for v in values):
            total = sum(values)
            out[key] = str(int(total)) if key.endswith("Tokens") else total
    out["_at"] = parts[-1]["_at"]
    out["_first_at"] = parts[0]["_at"]
    out["_first"] = parts[0]
    out["_chunks"] = len(parts)
    return out


def background_load(samples, start, end):
    if not samples or not start or not end:
        return None, ""
    lo, hi = start.strftime("%H:%M:%S.%f")[:-3], end.strftime("%H:%M:%S.%f")[:-3]
    window = [s for s in samples if lo <= s[0] <= hi]
    if not window:
        return None, ""
    gpu = sum(s[1] for s in window) / len(window)
    totals = {}
    for _, _, top in window:
        for item in filter(None, top.split(", ")):
            name, _, percent = item.rpartition(":")
            if "VoiceInk" in name:
                continue
            totals[name] = totals.get(name, 0) + float(percent)
    busiest = max(totals.items(), key=lambda kv: kv[1], default=None)
    label = f"{busiest[0]}:{busiest[1] / len(window):.0f}%" if busiest else ""
    return gpu, label


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--last", default="2h")
    parser.add_argument("--start")
    parser.add_argument("--load")
    args = parser.parse_args()

    dictations = group_dictations(read_events(args))
    samples = read_load(args.load) if args.load else []

    header = ["time", "rec", "gap", "asr", "punct", "pre", "chunks", "queue", "warm", "idle", "pfx", "prep",
              "prompt", "gen", "other", "xpc", "paste", "total", "therm", "qos"]
    if samples:
        header += ["bgGPU", "bgTop"]
    print("  ".join(h.rjust(5) if h not in ("time", "prompt", "gen", "bgTop") else h.ljust(8) for h in header))

    previous_paste = None
    for d in dictations:
        client = combined(d, "client-enhance")
        engine = combined(d, "engine-enhance")
        queue, xpc = number(client, "queue"), number(client, "xpc")
        requested_at = None
        first = client.get("_first", {})
        if first and number(first, "queue") is not None and number(first, "xpc") is not None:
            requested_at = first["_at"] - timedelta(seconds=number(first, "queue") + number(first, "xpc"))
        merge_at = d.get("merge", {}).get("_at") or client.get("_at")

        prompt_time, generate_time = number(engine, "prompt"), number(engine, "generate")
        known = [number(engine, k) for k in ("prepare", "encode")] + [prompt_time, generate_time]
        total_engine = number(engine, "total")
        other = total_engine - sum(known) if total_engine is not None and None not in known else None

        started = d["rec_start"] or d["asr_start"]
        row = [
            started.strftime("%H:%M:%S").ljust(8),
            fmt(seconds(d["rec_start"], d.get("asr_start"))),
            fmt(seconds(previous_paste, started), 5) if previous_paste else fmt(None),
            fmt(seconds(d.get("asr_start"), d.get("asr_end"))),
            fmt(number(d.get("punct", {}), "total"), 6) if "punct" in d else fmt(None),
            fmt(seconds(d.get("asr_end"), requested_at)),
            fmt(str(client.get("_chunks", "-"))),
            fmt(queue),
            fmt(engine.get("warm", "-")),
            fmt(number(engine, "idle")),
            fmt(engine.get("prefix", "-")),
            fmt(number(engine, "prepare")),
            f"{engine.get('promptTokens', '-')}/{fmt(prompt_time, 0).strip()}".ljust(8),
            f"{engine.get('outputTokens', '-')}/{fmt(generate_time, 0).strip()}".ljust(8),
            fmt(other),
            fmt(xpc),
            fmt(seconds(merge_at, d.get("paste"))),
            fmt(seconds(d.get("asr_start"), d.get("paste"))),
            fmt(engine.get("thermal", "-")),
            fmt(engine.get("qos", "-")),
        ]
        if samples:
            gpu, top = background_load(samples, d["rec_start"], d.get("asr_start"))
            row += [fmt(gpu), top]
        print("  ".join(row))
        previous_paste = d.get("paste") or previous_paste

    prepares = [d for d in dictations if "engine-prepare" in d or "punct-load" in d]
    if prepares:
        print("\n模型載入:")
        for d in prepares:
            started = f"{d['rec_start'] or d['asr_start']:%H:%M:%S}"
            if "punct-load" in d:
                print(f"  {started}  補標點 CT  load={d['punct-load'].get('load')}")
            if "engine-prepare" in d:
                p = d["engine-prepare"]
                print(f"  {started}  Breeze2  load={p.get('load')}  warmup={p.get('warmup')}  qos={p.get('qos')}")


if __name__ == "__main__":
    main()
