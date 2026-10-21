#!/usr/bin/python3
"""把 VoiceInk 設定成「Breeze 繁中辨識 + VoiceInk Refine（Breeze2）補標點」。可重複執行。

VoiceInk 必須先關掉（setup.sh configure 會處理），否則它結束時會把設定蓋回去。
需要先完成 VoiceInk 的初始設定，讓它建立第一個模式（Mode）。

會改的設定（UserDefaults 網域 com.prakashjoshipax.VoiceInk）：
  - CustomLanguagePrompts.zh  中文的 Whisper 提示詞；內建的是簡體，會把 Breeze 帶成簡體
  - modeConfigurationsV2      預設模式：Breeze 模型、中文、AI 潤稿用 VoiceInk Refine
                              （裝了 ZhTWPunctuation 模型時，Refine 就是繁中補標點）

用法：/usr/bin/python3 configure_voiceink.py [--dry-run]
"""

import json
import plistlib
import subprocess
import sys
import tempfile

DOMAIN = "com.prakashjoshipax.VoiceInk"
ASR_MODEL = "ggml-breeze-asr-25-q8_0"
SIMPLIFIED_DEFAULT_ZH_PROMPT = "你好，最近好吗？见到你很高兴。"
ZH_PROMPT = "你好，最近好嗎？今天用 Claude Code 測試語音輸入和標點符號，順便看一下 VoiceInk 的設定。"


def main():
    dry_run = "--dry-run" in sys.argv
    exported = subprocess.run(["defaults", "export", DOMAIN, "-"], capture_output=True, check=True).stdout
    prefs = plistlib.loads(exported)
    changes = []

    lang_prompts = dict(prefs.get("CustomLanguagePrompts") or {})
    if lang_prompts.get("zh", SIMPLIFIED_DEFAULT_ZH_PROMPT) == SIMPLIFIED_DEFAULT_ZH_PROMPT:
        lang_prompts["zh"] = ZH_PROMPT
        prefs["CustomLanguagePrompts"] = lang_prompts
        changes.append(f"中文 Whisper 提示詞 → {ZH_PROMPT}")

    if not prefs.get("modeConfigurationsV2"):
        sys.exit("找不到任何模式：請先打開 VoiceInk 完成初始設定，再執行一次。")
    modes = json.loads(prefs["modeConfigurationsV2"])
    mode = next((m for m in modes if m.get("isDefault")), modes[0])
    wanted = {
        "selectedTranscriptionModelName": ASR_MODEL,
        "selectedLanguage": "zh",
        "isAIEnhancementEnabled": True,
        "selectedAIProvider": "VoiceInk Refine",
        "selectedAIModel": "VoiceInk Refine V1",
        "useScreenCapture": False,
    }
    for key, value in wanted.items():
        if mode.get(key) != value:
            mode[key] = value
            changes.append(f"模式「{mode.get('name')}」{key} → {value}")
    prefs["modeConfigurationsV2"] = json.dumps(modes, ensure_ascii=False).encode("utf-8")

    if not changes:
        print("VoiceInk 設定已經是最新的，沒有要改的。")
        return
    for c in changes:
        print("  " + c)
    if dry_run:
        print("（--dry-run，沒有寫入）")
        return
    with tempfile.NamedTemporaryFile(suffix=".plist") as f:
        plistlib.dump(prefs, f, fmt=plistlib.FMT_BINARY)
        f.flush()
        subprocess.run(["defaults", "import", DOMAIN, f.name], check=True)
    print("VoiceInk 設定已寫入。")


if __name__ == "__main__":
    main()
