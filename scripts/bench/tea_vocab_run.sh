#!/bin/bash
# TEA 詞彙表的量測:同一批錄音跑 A(856d7c1)、B(v0.4.0)、C(v0.4.0 + 固定清單)、C2(v0.4.0 + 大清單),
# 跑兩輪,記辨識結果、時間和記憶體。做法見 docs/plan/2026-10-22-tea-vocabulary.md。
#
# 用法:tea_vocab_run.sh <工作資料夾> <輸出資料夾> [輪數,預設 2]
#   工作資料夾要有:
#     bin/tc_bench-856d7c1  連結 Beingpax 的 0.2.0-dev.856d7c1 xcframework
#     bin/tc_bench-v0.4.0   連結上游 v0.4.0 的 xcframework,用 -DTC_PROMPTING 編譯(見 tc_bench.c 開頭)
#     model.gguf            TEA-ASR-1.1 Q8_0(App 用的那個檔案,或指向它的 symlink)
#     list.tsv              id<TAB>wav(tea_vocab_diff.py list 產生)
#     terms.txt、terms-large.txt
#   跑的時候不要聽寫、不要跑其他評測。
set -euo pipefail

WORK="$1"
OUT="$2"
ROUNDS="${3:-2}"
mkdir -p "$OUT"

COMMON=(-m "$WORK/model.gguf" -i "$WORK/list.tsv" -l zh --max-chunk-sec 30 --boundary-sec 3 --window 1600)

run() {  # run <組> <輪> <tc_bench> [額外參數…]
    local arm="$1" round="$2" bin="$3"
    shift 3
    echo "== $arm round $round $(date +%H:%M:%S)"
    mkdir -p "$OUT/run$round"
    /usr/bin/time -l "$bin" "${COMMON[@]}" -o "$OUT/run$round/$arm.jsonl" "$@" 2> "$OUT/run$round/$arm.time.txt"
    sleep 20
}

pmset -g batt | head -2 > "$OUT/power-$(date +%H%M%S).txt"
for round in $(seq 1 "$ROUNDS"); do
    run A "$round" "$WORK/bin/tc_bench-856d7c1"
    run B "$round" "$WORK/bin/tc_bench-v0.4.0"
    run C "$round" "$WORK/bin/tc_bench-v0.4.0" --vocabulary-file "$WORK/terms.txt"
    run C2 "$round" "$WORK/bin/tc_bench-v0.4.0" --vocabulary-file "$WORK/terms-large.txt"
done
pmset -g batt | head -2 > "$OUT/power-$(date +%H%M%S).txt"
echo "== done $(date +%H:%M:%S)"
