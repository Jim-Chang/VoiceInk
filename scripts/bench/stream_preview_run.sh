#!/bin/bash
# 邊講邊出字的調查:依序跑 prefix、三種 loop(不顯示 / 每 30 秒切 / 每 10 秒切),
# 最後 macOS SpeechTranscriber 和 TEA(不顯示、照真實時間)同時跑。全程記 GPU 使用率。
# 設計見 docs/investigations/2026-10-22-streaming-preview.md。跑的時候不要聽寫、不要跑其他評測。
#
# 用法:stream_preview_run.sh <tc_stream_sim> <apple_stream_sim> <模型.gguf> <錄音資料夾> <輸出資料夾>
set -euo pipefail

SIM="$1"
APPLE="$2"
MODEL="$3"
REC="$4"
OUT="$5"
HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$OUT"

python3 -I "$HERE/stream_preview.py" lists "$REC" "$OUT"
pmset -g batt | head -2 > "$OUT/power-$(date +%H%M%S).txt"

python3 -I "$HERE/stream_preview.py" gpu-sample "$OUT/gpu-$(date +%H%M%S).tsv" &
SAMPLER=$!
trap 'kill $SAMPLER 2>/dev/null || true' EXIT

# 閒置時的 GPU 使用率(什麼都不跑 20 秒)
start=$(date +%s)
sleep 20
echo "{\"start\": $start, \"end\": $(date +%s)}" > "$OUT/idle-window.json"

echo "== prefix $(date +%H:%M:%S)"
/usr/bin/time -l "$SIM" -m "$MODEL" -i "$OUT/prefix.tsv" -o "$OUT/prefix.jsonl" -l zh \
    --mode prefix --prefixes 2,5,10,20,30,60 --repeat 3 2> "$OUT/prefix.time.txt"
sleep 20

for w in 0 30 10; do
    echo "== loop window=$w $(date +%H:%M:%S)"
    /usr/bin/time -l "$SIM" -m "$MODEL" -i "$OUT/loop.tsv" -o "$OUT/loop-w$w.jsonl" -l zh \
        --mode loop --window "$w" --interval 1 --first 1 --gap 5 --idle-cap 5 2> "$OUT/loop-w$w.time.txt"
    sleep 20
done

# Apple 的 SpeechTranscriber 和 TEA 同時跑:每段對齊開始,錄音結束時 TEA 照現在的做法辨識整段,
# 看 Apple 在旁邊跑會不會拖慢 TEA(結果是 loop-w0-with-apple)。
echo "== apple + tea $(date +%H:%M:%S)"
start=$(( $(date +%s) + 15 ))
/usr/bin/time -l "$APPLE" -i "$OUT/loop.tsv" -o "$OUT/apple.jsonl" --locale zh-TW \
    --start-at "$start" --slack 10 2> "$OUT/apple.time.txt" &
APPLE_PID=$!
/usr/bin/time -l "$SIM" -m "$MODEL" -i "$OUT/loop.tsv" -o "$OUT/loop-w0-with-apple.jsonl" -l zh \
    --mode loop --window 0 --idle-cap 100000 --start-at "$start" --slack 10 2> "$OUT/loop-w0-with-apple.time.txt"
wait $APPLE_PID
echo "== done $(date +%H:%M:%S)"
