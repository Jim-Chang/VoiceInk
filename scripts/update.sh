#!/bin/bash
# 更新 VoiceInk 繁中版（zhtw 分支）：合併原作者最新版 → 重新 build → 安裝到「應用程式」
#
# 用法：
#   scripts/update.sh            合併上游 Beingpax/VoiceInk 的 main，build、安裝
#   scripts/update.sh --no-pull  不合併，只 build、安裝（setup.sh 第一次安裝、改完程式碼時用）
#   scripts/update.sh --whisper  連同 ~/VoiceInk-Dependencies 裡的 whisper.cpp 一起更新重編
#
# 用 merge 而不是 rebase：zhtw 的修改紀錄會一直留著，也不用 force push。
# 合併後記得 git push origin zhtw。
set -euo pipefail

SRC="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="VoiceInk"
BUILT_APP="$HOME/Downloads/$APP_NAME.app"
INSTALLED_APP="/Applications/$APP_NAME.app"
WHISPER_FRAMEWORK="$HOME/VoiceInk-Dependencies/whisper.cpp/build-apple/whisper.xcframework"
UPSTREAM_URL="https://github.com/Beingpax/VoiceInk.git"

PULL=1
for arg in "$@"; do
    case "$arg" in
        --whisper) rm -rf "$WHISPER_FRAMEWORK"; echo "==> 會重新下載並編譯 whisper.cpp" ;;
        --no-pull) PULL=0 ;;
        *) echo "不認得的參數：$arg"; exit 1 ;;
    esac
done

cd "$SRC"
if [[ $PULL == 1 ]]; then
    # 找指向原作者的 remote；沒有就加一個叫 upstream 的
    UPSTREAM=$(git remote -v | awk '/Beingpax\/VoiceInk/ && /fetch/ {print $1; exit}')
    if [[ -z "$UPSTREAM" ]]; then
        git remote add upstream "$UPSTREAM_URL"
        UPSTREAM=upstream
    fi
    echo "==> 合併原作者最新版（$UPSTREAM/main）"
    git fetch "$UPSTREAM"
    if ! git merge --no-edit "$UPSTREAM/main"; then
        echo
        echo "合併有衝突，已停下來。解完衝突、git commit 之後，再執行 scripts/update.sh --no-pull"
        echo "或用 git merge --abort 放棄這次合併。"
        exit 1
    fi
fi

echo "==> 準備 sherpa-onnx 和補標點模型（已經有就跳過）"
"$SRC/scripts/deps-sherpa-onnx.sh"

echo "==> Build（第一次或重編 whisper.cpp 時會比較久）"
make local

if pgrep -x "$APP_NAME" > /dev/null; then
    echo "==> 關閉執行中的 $APP_NAME"
    osascript -e "quit app \"$APP_NAME\""
    while pgrep -x "$APP_NAME" > /dev/null; do sleep 1; done
fi

echo "==> 安裝到 $INSTALLED_APP"
rm -rf "$INSTALLED_APP"
ditto "$BUILT_APP" "$INSTALLED_APP"
rm -rf "$BUILT_APP"
# 編譯暫存約 3.6GB，make local 每次都會先砍掉重來，留著沒用
rm -rf .local-build

echo "==> 完成：$(git log -1 --format='%h %cd %s' --date=short)"
if [[ $PULL == 1 ]]; then
    echo "    合併了新的程式碼的話，記得 git push origin zhtw。"
fi
open "$INSTALLED_APP"
