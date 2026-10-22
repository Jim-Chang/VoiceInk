#!/usr/bin/python3
"""把 VoiceInk 設定成「TEA-ASR 繁中辨識 + 辨識完直接補標點（CT-Transformer）」。可重複執行。

VoiceInk 必須先關掉（setup.sh configure 會處理），否則它結束時會把設定蓋回去。
需要先完成 VoiceInk 的初始設定，讓它建立第一個模式（Mode）。

會改的設定（UserDefaults 網域 com.prakashjoshipax.VoiceInk）：
  - CustomLanguagePrompts.zh  中文的 Whisper 提示詞：只在舊設定是原作者的簡體句子時改掉
                              （這個 fork 的 App 內建預設已經是繁體，見 WhisperPrompt.swift；
                              只有換回 Breeze 這類 Whisper 模型時才用到）
  - modeConfigurationsV2      預設模式：TEA-ASR-1.1、中文、AI 潤稿關掉、文字格式化關掉
                              （補標點在辨識完就做了，見 ZhTWPunctuator，不靠 AI 潤稿；
                              文字格式化是給英文的，會在中文句號後面加空格、自動分段）
  - IsTranscriptionCleanupEnabled、TranscriptionRetentionMinutes
                              聽寫紀錄和錄音保留 3 天就自動刪除（歷史紀錄視窗的
                              「Auto-delete Transcript History」）；沒有對應紀錄的錄音檔也會被刪
  - IsAutoLearnDictionaryEnabled
                              關掉「自動學習」：它要用 AI 模型整理你改過的字，本機沒有合適的模型，
                              而且讀不到 Claude 的輸入框；順便清掉失敗紀錄
  - localCLICommandTemplate    v1 的補標點腳本（voiceink-zhtw/punct/punct.py）已經不在，清掉

用法：/usr/bin/python3 configure_voiceink.py [--dry-run]
"""

import json
import plistlib
import subprocess
import sys
import tempfile

DOMAIN = "com.prakashjoshipax.VoiceInk"
ASR_MODEL = "tea-asr-1.1"  # 換回 Breeze：ggml-breeze-asr-25-q8_0
SIMPLIFIED_DEFAULT_ZH_PROMPT = "你好，最近好吗？见到你很高兴。"
ZH_PROMPT = "你好，最近好嗎？見到你很高興。"


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
        "isAIEnhancementEnabled": False,
        "isTextFormattingEnabled": False,
        "useScreenCapture": False,
    }
    for key, value in wanted.items():
        if mode.get(key) != value:
            mode[key] = value
            changes.append(f"模式「{mode.get('name')}」{key} → {value}")
    prefs["modeConfigurationsV2"] = json.dumps(modes, ensure_ascii=False).encode("utf-8")

    retention = {
        "IsTranscriptionCleanupEnabled": True,
        "TranscriptionRetentionMinutes": 3 * 24 * 60,
    }
    for key, value in retention.items():
        if prefs.get(key) != value:
            prefs[key] = value
            changes.append(f"{key} → {value}")

    if prefs.get("IsAutoLearnDictionaryEnabled", True):
        prefs["IsAutoLearnDictionaryEnabled"] = False
        changes.append("IsAutoLearnDictionaryEnabled → False")
    # defaults import 只會新增、覆蓋，不會刪掉 key，要刪的另外用 defaults delete
    removals = []
    failure_keys = ["AutoLearnDictionaryFailureMessage", "AutoLearnDictionaryFailureAcknowledged"]
    if prefs.get("AutoLearnDictionaryHasFailure") or any(k in prefs for k in failure_keys):
        prefs["AutoLearnDictionaryHasFailure"] = False
        removals += [k for k in failure_keys if k in prefs]
        changes.append("清掉自動學習的失敗紀錄")
    if "voiceink-zhtw/punct/punct.py" in prefs.get("localCLICommandTemplate", ""):
        removals.append("localCLICommandTemplate")
        changes.append("清掉指向 v1 補標點腳本的 Local CLI 指令")

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
    for key in removals:
        subprocess.run(["defaults", "delete", DOMAIN, key], check=True)
    print("VoiceInk 設定已寫入。")


if __name__ == "__main__":
    main()
