#!/bin/bash
# 準備補標點用的 sherpa-onnx 函式庫、標頭檔和 CT-Transformer 模型,放到 ~/VoiceInk-Dependencies/sherpa-onnx/。
# Xcode 專案引用這裡的檔案(和 whisper.xcframework 一樣),build 時嵌入 App。
# 固定版本、核對 SHA256;已經準備好就跳過,可以重複執行。
#
# 用法:
#   scripts/deps-sherpa-onnx.sh          準備(setup.sh、update.sh 會在 build 前呼叫)
#   scripts/deps-sherpa-onnx.sh check    只檢查,沒準備好時回傳 1
set -euo pipefail

VERSION="1.13.8"
DEST="$HOME/VoiceInk-Dependencies/sherpa-onnx"

LIB_NAME="sherpa-onnx-v$VERSION-osx-arm64-shared-no-tts-lib"
LIB_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/v$VERSION/$LIB_NAME.tar.bz2"
LIB_SHA256="f3e0cbd86cc3f38dad30c97921b40e9a8bcc6f2c943777eb76ad77176993e417"

HEADER_URL="https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/v$VERSION/sherpa-onnx/c-api/c-api.h"
HEADER_SHA256="2a1b95084be8fd1deb3228fcad2fd3f7f0258b64582f7402281ec174c7b7f4ce"

# FunASR 的 CT-Transformer(中英文標點),sherpa-onnx 轉成 ONNX 的 int8 版
MODEL_NAME="sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12-int8"
MODEL_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/punctuation-models/$MODEL_NAME.tar.bz2"
MODEL_SHA256="c0d5aa5f8eeb686032345e180bedf39319dc2e0556781c6264bcadba8328a6e1"
MODEL_FILE_SHA256="65a3fb9f5ad7bfb96bf69e0dc4481df97f6ee60513c1d94ce981ba6effd524b1"

STAMP="$DEST/.stamp"
STAMP_CONTENT="$LIB_SHA256 $HEADER_SHA256 $MODEL_FILE_SHA256"

ready() {
    [[ -f "$STAMP" && "$(cat "$STAMP")" == "$STAMP_CONTENT" ]] \
        && [[ -f "$DEST/lib/libsherpa-onnx-c-api.dylib" && -f "$DEST/lib/libonnxruntime.dylib" ]] \
        && [[ -f "$DEST/include/c-api.h" && -f "$DEST/include/module.modulemap" ]] \
        && [[ -f "$DEST/$MODEL_NAME/model.int8.onnx" ]]
}

download() {  # 網址 檔案 SHA256
    curl -L --fail --silent --show-error -o "$2" "$1"
    echo "$3  $2" | shasum -a 256 -c - > /dev/null
}

if [[ "${1:-}" == check ]]; then
    ready && echo "sherpa-onnx $VERSION 已準備好:$DEST" && exit 0
    echo "sherpa-onnx 還沒準備好:scripts/deps-sherpa-onnx.sh"
    exit 1
fi

if ready; then
    echo "sherpa-onnx $VERSION 已準備好,跳過"
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> 下載 sherpa-onnx $VERSION 函式庫(8MB)"
download "$LIB_URL" "$WORK/lib.tar.bz2" "$LIB_SHA256"
mkdir "$WORK/lib"
tar -xjf "$WORK/lib.tar.bz2" -C "$WORK/lib"

echo "==> 下載標頭檔"
download "$HEADER_URL" "$WORK/c-api.h" "$HEADER_SHA256"

echo "==> 下載補標點模型 $MODEL_NAME(65MB)"
download "$MODEL_URL" "$WORK/model.tar.bz2" "$MODEL_SHA256"
mkdir "$WORK/model"
tar -xjf "$WORK/model.tar.bz2" -C "$WORK/model" "$MODEL_NAME/model.int8.onnx" "$MODEL_NAME/README.md"
echo "$MODEL_FILE_SHA256  $WORK/model/$MODEL_NAME/model.int8.onnx" | shasum -a 256 -c - > /dev/null

rm -rf "$DEST"
mkdir -p "$DEST/lib" "$DEST/include"
# App 只用 C API;它會自己載入同一個資料夾裡的 libonnxruntime.dylib(@rpath = @loader_path)
cp "$WORK/lib/$LIB_NAME/lib/libsherpa-onnx-c-api.dylib" "$WORK/lib/$LIB_NAME/lib/libonnxruntime.dylib" "$DEST/lib/"
cp "$WORK/c-api.h" "$DEST/include/"
cat > "$DEST/include/module.modulemap" <<'EOF'
module SherpaOnnxC {
    header "c-api.h"
    export *
}
EOF
mv "$WORK/model/$MODEL_NAME" "$DEST/"
echo "$STAMP_CONTENT" > "$STAMP"
echo "==> 完成:$DEST"
