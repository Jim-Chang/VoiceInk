#!/bin/bash
# 編譯並執行 RefineBench:離線跑 App 裡的補標點引擎(VoiceInkRefineInferenceEngine)和合併邏輯。
# 用法:scripts/bench/refine-bench.sh <輸入.json> <輸出.json> <prefix|session> [whole|chunk]
# 模型預設用 VoiceInk 的 Breeze2 資料夾,可用 ZHTW_MODEL_DIR 指定。
# 第一次 build 要編 MLX(數分鐘);暫存在 ZHTW_BENCH_DIR(預設 $TMPDIR/zhtw-refine-bench)。
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT=$PWD
OUT=${ZHTW_BENCH_DIR:-${TMPDIR:-/tmp}/zhtw-refine-bench}
MODEL=${ZHTW_MODEL_DIR:-$HOME/Library/Application Support/com.prakashjoshipax.VoiceInk/ZhTWPunctuation/Llama-Breeze2-3B-Instruct-Text-mlx-4Bit}

mkdir -p "$OUT/Sources/RefineBench"
cp scripts/bench/RefineBench/Package.swift "$OUT/"
cp VoiceInk.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved "$OUT/" 2>/dev/null || true
cp scripts/bench/RefineBench/main.swift \
   VoiceInkRefineXPC/VoiceInkRefineInferenceEngine.swift \
   VoiceInkRefineXPC/ZhTWTiming.swift \
   VoiceInk/Features/ZhTW/ZhTWPunctuation.swift \
   "$OUT/Sources/RefineBench/"

(cd "$OUT" && xcodebuild -scheme RefineBench -destination 'platform=macOS,arch=arm64' \
    -configuration Release -derivedDataPath "$OUT/.xcode" \
    -skipMacroValidation -skipPackagePluginValidation build > "$OUT/build.log" 2>&1) \
  || { grep -E "error:" "$OUT/build.log" | head -20; echo "build 失敗,見 $OUT/build.log"; exit 1; }

"$OUT/.xcode/Build/Products/Release/RefineBench" "$MODEL" "$@"
