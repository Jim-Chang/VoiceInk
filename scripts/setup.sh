#!/bin/bash
# 在一台新的 Apple Silicon Mac 上架起「VoiceInk + TEA-ASR 繁中聽寫 + 本機補標點」（單一 App 版）。
# 每一步都會先檢查，做過的就跳過，可以放心重複執行。
#
# 用法（在這個 repo 裡）：
#   scripts/setup.sh             安裝全部：Xcode 工具、build VoiceInk、下載模型
#   scripts/setup.sh --with-breeze
#                                另外下載備用的語音辨識模型 Breeze-ASR-25（1.7GB）
#   scripts/setup.sh configure   寫入 VoiceInk 設定（要先在 VoiceInk 完成初始設定）
#   scripts/setup.sh check       只檢查目前狀態，不改任何東西
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_SUPPORT="$HOME/Library/Application Support/com.prakashjoshipax.VoiceInk"

# 語音辨識：TEA-ASR-1.1（transcribe.cpp 的 GGUF，自己轉檔，見 docs/plan/2026-10-22-tea-asr.md）
# 放的位置、檔名、大小、SHA256 要和 App 的 TranscribeCppModelCatalog.teaASR11 相同，App 才會當成已安裝
TEA_DIR="$APP_SUPPORT/TranscribeCpp/tea-asr-1.1"
TEA_FILE="TEA-ASR-1.1-Q8_0.gguf"
TEA_URL="https://huggingface.co/dorajim15/TEA-ASR-1.1-transcribe-cpp/resolve/cc49fae1183e7458411663c2a39de1fdfef8ff7a/$TEA_FILE"
TEA_SIZE=2184763808
TEA_SHA256="2e4aeb45c9e7f421d99909e29e49a54e204d70ed0e77bebc3f18a135d78298d0"

# 備用語音辨識（選用，--with-breeze）：聯發科 Breeze-ASR-25（whisper.cpp 格式，社群轉檔）
ASR_DIR="$APP_SUPPORT/WhisperModels"
ASR_FILE="ggml-breeze-asr-25-q8_0.bin"
ASR_URL="https://huggingface.co/shdennlin/breeze-asr-25-ggml/resolve/main/$ASR_FILE"
ASR_SHA256="d4b187c40ffbf1f620734b77821e2ca8a97c8ecf5754d02b2a175069348cafcf"

# 補標點：聯發科 Breeze2-3B（MLX 4bit，社群轉檔），由 VoiceInk Refine 的引擎執行
LLM_DIR="$APP_SUPPORT/ZhTWPunctuation/Llama-Breeze2-3B-Instruct-Text-mlx-4Bit"
LLM_REPO="MXLouis/Llama-Breeze2-3B-Instruct-Text-mlx-4Bit"
LLM_REVISION="acaf955132f32bad52549274be74612028601d01"
LLM_FILES=(config.json generation_config.json chat_template.jinja special_tokens_map.json
           tokenizer_config.json tokenizer.json model.safetensors.index.json model.safetensors)
LLM_SHA256_MODEL="0df793d7dce10428d3e70e8ed8b40c1a944fa38c7b86f44a27a3d8d3f80fce92"
LLM_SHA256_TOKENIZER="a8f58896d94c1728235bcfee5694a7c62c6666fdfb6b9b6810a3f839bc4e72f8"

ok()   { echo "  ✓ $*"; }
todo() { echo "  ✗ $*"; }
step() { echo; echo "==> $*"; }

memory_gb()     { echo $(( $(sysctl -n hw.memsize) / 1073741824 )); }
has_xcode()     { xcodebuild -version > /dev/null 2>&1; }
has_metal()     { xcrun -f metal > /dev/null 2>&1; }
has_app()       { [[ -d /Applications/VoiceInk.app ]]; }
app_has_zhtw()  { [[ -f /Applications/VoiceInk.app/Contents/Resources/sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12-int8/model.int8.onnx ]]; }
has_asr()       { [[ -f "$ASR_DIR/$ASR_FILE" ]]; }
# 和 App 的判斷一樣：大小相符、.sha256 檔的內容相符（下載時已經核對過 SHA256）
has_tea()       {
    [[ -f "$TEA_DIR/$TEA_FILE" && "$(stat -f %z "$TEA_DIR/$TEA_FILE")" == "$TEA_SIZE" ]] &&
        [[ "$(tr -d '[:space:]' < "$TEA_DIR/.$TEA_FILE.sha256" 2>/dev/null)" == "$TEA_SHA256" ]]
}
has_llm()       { [[ -f "$LLM_DIR/model.safetensors" && -f "$LLM_DIR/tokenizer.json" && -f "$LLM_DIR/config.json" ]]; }
configured()    {
    defaults export com.prakashjoshipax.VoiceInk - 2>/dev/null | /usr/bin/python3 -c '
import plistlib, json, sys
p = plistlib.loads(sys.stdin.buffer.read())
m = next(x for x in json.loads(p["modeConfigurationsV2"]) if x.get("isDefault"))
sys.exit(0 if m.get("selectedTranscriptionModelName") == "tea-asr-1.1" and m.get("selectedLanguage") == "zh" and not m.get("isAIEnhancementEnabled") and not m.get("isTextFormattingEnabled") and p.get("IsTranscriptionCleanupEnabled") and p.get("TranscriptionRetentionMinutes") == 4320 else 1)' 2>/dev/null
}

check() {
    step "目前狀態"
    if [[ "$(uname -m)" == arm64 ]]; then ok "Apple Silicon"; else todo "不是 Apple Silicon"; fi
    if (( $(memory_gb) >= 16 )); then ok "記憶體 $(memory_gb)GB"; else todo "記憶體 $(memory_gb)GB（VoiceInk Refine 需要 16GB 以上）"; fi
    if has_xcode; then ok "Xcode"; else todo "Xcode（請從 App Store 安裝並打開一次）"; fi
    if has_metal; then ok "Metal 工具鏈"; else todo "Metal 工具鏈"; fi
    if command -v cmake > /dev/null; then ok "cmake"; else todo "cmake"; fi
    if "$SCRIPTS_DIR/deps-sherpa-onnx.sh" check > /dev/null; then ok "sherpa-onnx 和補標點模型（build 用）"; else todo "sherpa-onnx 和補標點模型（build 時會自動下載）"; fi
    if app_has_zhtw; then ok "VoiceInk.app（含繁中補標點）"
    elif has_app; then todo "VoiceInk.app 是沒有繁中補標點的版本（scripts/update.sh --no-pull 重裝）"
    else todo "VoiceInk.app"; fi
    if has_tea; then ok "語音辨識模型 TEA-ASR-1.1"; else todo "語音辨識模型 TEA-ASR-1.1"; fi
    if has_asr; then ok "備用語音辨識模型 $ASR_FILE"; else echo "  - 備用語音辨識模型 Breeze-ASR-25 沒裝（選用：scripts/setup.sh --with-breeze）"; fi
    if has_llm; then ok "補標點模型 Breeze2-3B"; else todo "補標點模型 Breeze2-3B"; fi
    if configured; then ok "VoiceInk 設定"; else todo "VoiceInk 設定（scripts/setup.sh configure）"; fi
}

download_llm() {
    mkdir -p "$LLM_DIR"
    for f in "${LLM_FILES[@]}"; do
        [[ -f "$LLM_DIR/$f" ]] && continue
        echo "  下載 $f"
        curl -L --fail -C - -o "$LLM_DIR/$f.part" "https://huggingface.co/$LLM_REPO/resolve/$LLM_REVISION/$f"
        mv "$LLM_DIR/$f.part" "$LLM_DIR/$f"
    done
    (cd "$LLM_DIR" && shasum -a 256 -c - <<EOF
$LLM_SHA256_MODEL  model.safetensors
$LLM_SHA256_TOKENIZER  tokenizer.json
EOF
    )
}

install_all() {
    [[ "$(uname -m)" == arm64 ]] || { echo "需要 Apple Silicon Mac"; exit 1; }
    (( $(memory_gb) >= 16 )) || { echo "VoiceInk Refine 需要 16GB 以上記憶體"; exit 1; }

    step "Xcode 和編譯工具"
    has_xcode || { echo "請先從 App Store 安裝 Xcode，打開一次同意授權，再重跑這個腳本。"; exit 1; }
    ok "Xcode"
    if ! has_metal; then
        echo "  Xcode 26 起 Metal 工具鏈要另外下載（VoiceInk 的 MLX 需要，約 700MB）"
        xcodebuild -downloadComponent MetalToolchain
    fi
    ok "Metal 工具鏈"
    if ! command -v cmake > /dev/null; then
        command -v brew > /dev/null || { echo "需要 Homebrew 來裝 cmake：https://brew.sh"; exit 1; }
        brew install cmake
    fi
    ok "cmake"

    step "Build 並安裝 VoiceInk（第一次要編譯 whisper.cpp，會比較久）"
    app_has_zhtw || "$SCRIPTS_DIR/update.sh" --no-pull
    ok "VoiceInk.app"

    step "語音辨識模型（TEA-ASR-1.1，2.2GB）"
    if ! has_tea; then
        mkdir -p "$TEA_DIR"
        curl -L --fail -C - -o "$TEA_DIR/$TEA_FILE.part" "$TEA_URL"
        echo "$TEA_SHA256  $TEA_DIR/$TEA_FILE.part" | shasum -a 256 -c -
        # 和 App 下載完一樣：先寫 .sha256 再把模型檔放到位
        printf '%s' "$TEA_SHA256" > "$TEA_DIR/.$TEA_FILE.sha256"
        mv "$TEA_DIR/$TEA_FILE.part" "$TEA_DIR/$TEA_FILE"
    fi
    ok "$TEA_DIR/$TEA_FILE"

    if [[ $WITH_BREEZE == 1 ]]; then
        step "備用語音辨識模型（Breeze-ASR-25，1.7GB）"
        if ! has_asr; then
            mkdir -p "$ASR_DIR"
            curl -L --fail -C - -o "$ASR_DIR/$ASR_FILE.part" "$ASR_URL"
            echo "$ASR_SHA256  $ASR_DIR/$ASR_FILE.part" | shasum -a 256 -c -
            mv "$ASR_DIR/$ASR_FILE.part" "$ASR_DIR/$ASR_FILE"
        fi
        ok "$ASR_DIR/$ASR_FILE"
    fi

    step "補標點模型（Breeze2-3B，2GB）"
    has_llm || download_llm
    ok "$LLM_DIR"

    step "還需要你手動做的事"
    cat <<EOF
  1. 打開 VoiceInk 完成初始設定
     - 允許麥克風、輔助使用權限（macOS 規定要本人點）
     - 「模型」那一步只能選 Parakeet 或雲端：選 Local 下載 Parakeet 過關，之後可刪
     - 設定錄音快捷鍵（建議右邊 Option + Hybrid）
  2. 完成後執行：scripts/setup.sh configure
EOF
}

configure() {
    step "寫入 VoiceInk 設定"
    local was_running=0
    if pgrep -x VoiceInk > /dev/null; then
        was_running=1
        osascript -e 'quit app "VoiceInk"'
        while pgrep -x VoiceInk > /dev/null; do sleep 0.5; done
    fi
    has_tea || echo "  注意：TEA-ASR-1.1 還沒下載（scripts/setup.sh），模式會選到還沒裝的模型"
    mkdir -p "$APP_SUPPORT/zhtw-backups"
    defaults export com.prakashjoshipax.VoiceInk \
        "$APP_SUPPORT/zhtw-backups/prefs-$(date +%Y%m%d-%H%M%S).plist" 2>/dev/null || true
    /usr/bin/python3 "$SCRIPTS_DIR/configure_voiceink.py"
    if [[ $was_running == 1 ]]; then open /Applications/VoiceInk.app; fi
    echo "  設定備份在 $APP_SUPPORT/zhtw-backups/"
}

COMMAND=install
WITH_BREEZE=0
for arg in "$@"; do
    case "$arg" in
        install|configure|check) COMMAND=$arg ;;
        --with-breeze) WITH_BREEZE=1 ;;
        *) echo "用法：scripts/setup.sh [install|configure|check] [--with-breeze]"; exit 1 ;;
    esac
done

case "$COMMAND" in
    install) install_all; check ;;
    configure) configure ;;
    check) check ;;
esac
