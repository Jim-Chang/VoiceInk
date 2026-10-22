#!/bin/bash
# TEA 批次辨識的量測(docs/plan/2026-10-23-tea-batch.md):一組設定一個行程,用 /usr/bin/time -l 記尖峰記憶體。
# 跑的時候不要聽寫、不要跑其他評測(互搶 GPU 時間會失真)。
# 用法:tea_batch_run.sh tc_bench 模型.gguf list.tsv 輸出資料夾 名稱 批次大小 [tc_bench 其他參數,例如 --sort-length]
# 輸出:輸出資料夾/名稱.jsonl(tc_bench,含文字)、名稱.time(tc_bench 的 stderr 和 /usr/bin/time -l)。
# 切段照 App:30 秒、在最後 3 秒找最安靜的地方;停下的段切兩半重跑(--retry-split)。
set -euo pipefail
tc_bench=$1 model=$2 list=$3 out=$4 name=$5 batch=$6
shift 6
mkdir -p "$out"
/usr/bin/time -l "$tc_bench" -m "$model" -i "$list" -o "$out/$name.jsonl" -l zh --itn default \
    --max-chunk-sec 30 --boundary-sec 3 --window 1600 --batch "$batch" --retry-split "$@" 2> "$out/$name.time"
grep -E '^batch |peak memory footprint' "$out/$name.time" || true
