# 聽寫工具與語音辨識模型:為什麼是 VoiceInk + Breeze-ASR-25

2026-10-21。起點:Claude Code 桌面版的語音輸入講普通話會輸出簡體,想找能穩定輸出繁體、而且更準的做法。

## Claude Code 內建語音輸入

- 官方文件說聽寫語言由 settings 的 `language` 控制,支援的 20 種語言**沒有中文**;設成中文會退回英文([voice-dictation](https://code.claude.com/docs/en/voice-dictation))。
- 沒有另外的聽寫語言設定;上游有 issue 在追蹤:[anthropics/claude-code#78728](https://github.com/anthropics/claude-code/issues/78728)。
- 結論:等官方支援之前,改用外部聽寫工具,把文字貼進輸入框。

## macOS 內建聽寫

| | |
|---|---|
| 優點 | 免安裝、邊講邊出字、選「中文(台灣)」就輸出繁體 |
| 缺點 | Apple 沒公布中文準確率。唯一找到的數據是一位開發者用 SpeechAnalyzer 測中文**會議錄音**,字錯率約 34%(不是近距離聽寫,只能參考);中英夾雜容易錯 |

## 開源語音辨識模型(中文)

| 模型 | 開發者 | 輸出繁體? | 說明 |
|---|---|---|---|
| **Breeze-ASR-25** | 聯發科 | 直接輸出繁體 | Whisper large-v2 微調,針對台灣華語、中英夾雜。官方說比 Whisper 準約 10%、中英夾雜進步 56%(自報)。Apache 2.0 |
| Qwen3-ASR | 阿里 | 簡體 | 中文很強,22 種方言 |
| FireRedASR | 小紅書 | 簡體 | 中文評測字錯率約 3%(Whisper large-v3 約 9.9%),但 Mac 上沒有現成聽寫 App |
| Whisper large-v3 / turbo | OpenAI | 簡繁混雜 | 支援的 App 最多,中文普通 |

## Mac 上的開源聽寫 App

| App | 授權 | 能用 Breeze-ASR-25? | 說明 |
|---|---|---|---|
| **VoiceInk** | GPLv3 | 能(匯入 whisper.cpp 格式 `.bin`) | 快捷鍵錄音、貼到任何 App;官網版付費,自己 build 免費 |
| Handy | MIT | 不能(只有 Whisper、Parakeet) | 最熱門、跨平台 |
| TypelessMLX | 未標授權 | 預設就是 Breeze-ASR-25 | 專案很小(33 星) |
| Qwen Scribe | Apache 2.0 | 不能(Qwen3-ASR) | 輸出簡體 |

## 記憶體與速度(M1 Pro 32GB)

- Breeze-ASR-25 q8_0:檔案 1.66GB,執行時估計約 2.7GB(whisper.cpp 的 large 模型比檔案大約多 1GB)。
- 實測辨識時間:講 15 秒約 2.1 秒、短句 1.2–1.5 秒。

## 不能「邊講邊輸入」

- Breeze-ASR-25 是 Whisper 類模型,要聽完一段才辨識;VoiceInk 只有 Parakeet、Nemotron(英文/歐洲語言為主)和雲端服務支援串流。
- 就算開了即時轉錄,VoiceInk 也只把即時文字顯示在自己的錄音面板(`MiniRecorderView` / `NotchRecorderView`),講完才一次貼進目前的 App。

## 建議

**VoiceInk(自己 build)+ Breeze-ASR-25 q8_0。** 唯一同時滿足「開源、能用台灣華語模型、直接輸出繁體、能貼進任何 App」的組合。macOS 內建聽寫當備案(需要邊講邊出字時)。

辨識錯字(例如講太快、音黏在一起)來自 Breeze-ASR,補標點那一步不會改字。改善順序:換近一點的麥克風 → 在中文 Whisper 提示詞放常用詞 → VoiceInk 的 Word Replacements。

## 來源

- [Breeze-ASR-25(聯發科)](https://huggingface.co/MediaTek-Research/Breeze-ASR-25)、[whisper.cpp 格式轉檔](https://huggingface.co/shdennlin/breeze-asr-25-ggml)
- [FireRedASR](https://github.com/FireRedTeam/FireRedASR)、[Qwen3-ASR 技術報告](https://arxiv.org/pdf/2601.21337)
- [VoiceInk](https://github.com/Beingpax/VoiceInk)、[Handy](https://github.com/cjpais/Handy)、[TypelessMLX](https://github.com/rock74710/TypelessMLX)
- [Apple SpeechAnalyzer 評測報導](https://www.gigazine.net/gsc_news/en/20260714-apple-speech-analyzer-benchmark/)
