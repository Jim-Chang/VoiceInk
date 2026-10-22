#!/bin/bash
# 換語音辨識模型的調查:依序跑每個模型(一次只跑一個),記辨識結果、時間和記憶體。
# 參數和做法見 docs/investigations/2026-10-22-asr-models.md。
#
# 用法:asr_models_run.sh <工作資料夾> <輸出資料夾> [模型代號…]
#   工作資料夾要有:bin/tc_bench、all.tsv(id<TAB>wav)、models/<代號>.gguf、
#                   whisper/whisper-cli、whisper/ggml-breeze-asr-25-q8_0.bin、whisper/ggml-silero-v5.1.2.bin
#   沒給模型代號就全部跑。跑的時候不要聽寫、不要跑其他評測。
set -euo pipefail

WORK="$1"
OUT="$2"
shift 2
MODELS=("$@")
if [ ${#MODELS[@]} -eq 0 ]; then
    MODELS=(breeze sensevoice qwen-mini tea-mini qwen tea funasr-nano)
fi
HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$OUT"

pmset -g batt | head -2 > "$OUT/power-$(date +%H%M%S).txt"

for name in "${MODELS[@]}"; do
    echo "== $name $(date +%H:%M:%S)"
    case "$name" in
        breeze)
            python3 -I "$HERE/asr_bench.py" --cli "$WORK/whisper/whisper-cli" \
                --vad-model "$WORK/whisper/ggml-silero-v5.1.2.bin" \
                --audio-dir "$WORK/recordings" --input "$WORK/transcripts.json" \
                --output "$OUT/breeze.json" --variant "q8=$WORK/whisper/ggml-breeze-asr-25-q8_0.bin"
            # 記憶體:用最長的一段單獨跑一次
            longest="$(python3 -I -c 'import json,sys; d=[i for i in json.load(open(sys.argv[1])) if i.get("has_audio")]; print(max(d, key=lambda i: i["duration"])["id"])' "$WORK/transcripts.json")"
            /usr/bin/time -l "$WORK/whisper/whisper-cli" -m "$WORK/whisper/ggml-breeze-asr-25-q8_0.bin" \
                -f "$WORK/recordings/$longest.wav" -l zh --prompt "你好，最近好嗎？見到你很高興。" \
                -t 8 -bs 1 -bo 5 -tp 0.2 -fa -nt --vad -vm "$WORK/whisper/ggml-silero-v5.1.2.bin" \
                -vt 0.5 -vspd 250 -vsd 100 -vp 30 -vo 0.1 > /dev/null 2> "$OUT/breeze.time.txt"
            ;;
        sensevoice)
            /usr/bin/time -l "$WORK/bin/tc_bench" -m "$WORK/models/sensevoice.gguf" -i "$WORK/all.tsv" \
                -o "$OUT/sensevoice.jsonl" -l zh --itn on --max-chunk-sec 30 --boundary-sec 3 --window 1600 \
                2> "$OUT/sensevoice.time.txt"
            ;;
        funasr-nano)
            /usr/bin/time -l "$WORK/bin/tc_bench" -m "$WORK/models/funasr-nano.gguf" -i "$WORK/all.tsv" \
                -o "$OUT/funasr-nano.jsonl" -l zh --itn on 2> "$OUT/funasr-nano.time.txt"
            ;;
        qwen-mini|qwen|tea-mini|tea)
            /usr/bin/time -l "$WORK/bin/tc_bench" -m "$WORK/models/$name.gguf" -i "$WORK/all.tsv" \
                -o "$OUT/$name.jsonl" -l zh 2> "$OUT/$name.time.txt"
            ;;
        *)
            echo "unknown model $name" >&2
            exit 2
            ;;
    esac
    sleep 20
done
echo "== done $(date +%H:%M:%S)"
