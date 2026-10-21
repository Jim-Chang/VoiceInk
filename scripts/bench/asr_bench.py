#!/usr/bin/env python3
"""實驗 B:用 whisper-cli 離線跑同一批錄音,比較不同的 Breeze-ASR-25 版本的速度和辨識結果。

參數照 VoiceInk 實際用的(VoiceInk/Infrastructure/Providers/Transcription/Whisper/LibWhisper.swift):
中文、繁體提示詞、greedy、temperature 0.2、best_of 5、8 執行緒、flash attention、
VAD(silero v5.1.2,門檻 0.5、最短語音 250ms、最短靜音 100ms、前後補 30ms、重疊 0.1 秒)。

用法:
  python3 -I scripts/bench/asr_bench.py --cli whisper-cli --vad-model ggml-silero-v5.1.2.bin \\
      --audio-dir Recordings --input transcripts.json --output B-results.json \\
      --variant f16=models/f16/ggml-breeze-asr-25-f16.bin --variant q8=... [--prompt ...]

- 每個版本放在自己的資料夾:whisper.cpp 會自動使用同資料夾裡的 Core ML 編碼器
  (q8_0、q5_0、q4_k 都找 ggml-breeze-asr-25-encoder.mlmodelc),混在一起會互相影響。
- 每段錄音各開一次 whisper-cli;「辨識時間」= total time - load time(載入在 App 裡藏在錄音期間)。
- 每個版本先用第一段錄音暖機一次(檔案快取、Core ML 第一次編譯),暖機的時間另外記。
"""
import argparse
import json
import pathlib
import re
import subprocess
import time

TIMING = re.compile(r"whisper_print_timings:\s+(\w[\w ]*?) time =\s+([\d.]+) ms")


def audio_ctx(duration):
    """--audio-ctx dynamic:編碼器只處理錄音實際的長度(多留 1 秒),上限 1500(= 30 秒)"""
    return min(1500, int((duration + 1) / 30 * 1500) + 1)


def run(cli, model, wav, args, duration=None):
    command = [
        cli, "-m", model, "-f", wav, "-l", "zh", "--prompt", args.prompt,
        "-t", "8", "-bs", "1", "-bo", "5", "-tp", "0.2", "-fa", "-nt",
        "--vad", "-vm", args.vad_model, "-vt", "0.5", "-vspd", "250", "-vsd", "100",
        "-vp", "30", "-vo", "0.1",
    ]
    if args.audio_ctx == "dynamic" and duration is not None:
        command += ["-ac", str(audio_ctx(duration))]
    started = time.monotonic()
    proc = subprocess.run(command, capture_output=True, text=True)
    wall = time.monotonic() - started
    timings = {name.strip(): float(ms) / 1000 for name, ms in TIMING.findall(proc.stderr)}
    text = "".join(line.strip() for line in proc.stdout.splitlines())
    coreml = "Core ML model loaded" in proc.stderr
    return {
        "text": text,
        "load": timings.get("load"),
        "total": timings.get("total"),
        "encode": timings.get("encode"),
        "decode": timings.get("decode"),
        "transcribe": (timings["total"] - timings["load"]) if "total" in timings and "load" in timings else None,
        "wall": wall,
        "coreml": coreml,
        "ok": proc.returncode == 0,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--cli", required=True)
    parser.add_argument("--vad-model", required=True)
    parser.add_argument("--audio-dir", required=True)
    parser.add_argument("--input", required=True, help="transcripts.json(id 對應錄音檔名)")
    parser.add_argument("--output", required=True)
    parser.add_argument("--variant", action="append", required=True, help="名稱=模型路徑")
    parser.add_argument("--prompt", default="你好，最近好嗎？見到你很高興。")
    parser.add_argument("--audio-ctx", choices=["full", "dynamic"], default="full",
                        help="dynamic = 編碼器只處理錄音實際長度(whisper.cpp 的 audio_ctx)")
    parser.add_argument("--max-duration", type=float, help="只跑不超過這麼多秒的錄音")
    parser.add_argument("--limit", type=int, help="只跑前幾段")
    args = parser.parse_args()

    items = [i for i in json.load(open(args.input, encoding="utf-8")) if i.get("has_audio")]
    if args.max_duration:
        items = [i for i in items if i["duration"] <= args.max_duration]
    if args.limit:
        items = items[:args.limit]
    audio = pathlib.Path(args.audio_dir)
    results = {"prompt": args.prompt, "variants": {}}
    for spec in args.variant:
        name, model = spec.split("=", 1)
        warm = run(args.cli, model, str(audio / f"{items[0]['id']}.wav"), args, items[0]["duration"])
        print(f"{name}: 暖機 wall={warm['wall']:.1f}s load={warm['load']} coreml={warm['coreml']}", flush=True)
        rows = {}
        for item in items:
            rows[item["id"]] = run(args.cli, model, str(audio / f"{item['id']}.wav"), args, item["duration"])
        results["variants"][name] = {"model": model, "warmup": warm, "rows": rows}
        done = [r for r in rows.values() if r["transcribe"] is not None]
        print(f"{name}: {len(done)}/{len(rows)} 段, 辨識合計 {sum(r['transcribe'] for r in done):.1f}s", flush=True)
        json.dump(results, open(args.output, "w", encoding="utf-8"), ensure_ascii=False, indent=1)


if __name__ == "__main__":
    main()
