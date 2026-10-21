# v1:VoiceInk + LM Studio(兩個 App)

2026-10-21。已完成,之後由 [v2](2026-10-21-v2-single-app.md) 取代。完整的腳本、測試數據(含實際聽寫內容)在私人 repo `voiceink-zhtw-lmstudio`,標籤 `v1-two-apps`;這裡只留做法與紀錄。

## 背景與目標

Breeze-ASR-25 的辨識結果沒有標點。目標:用本機小模型補標點,一定是繁體、不改字。

## 做法

```
VoiceInk(原版,自己 build)
  └─ AI 潤稿:Local CLI → /usr/bin/python3 punct.py
         ↓ http://127.0.0.1:1234
       LM Studio 伺服器 → Breeze2-3B(MLX 4bit)
         ↓
       punct.py 對齊原文,只取標點
```

- `punct.py`:只用 Python 標準函式庫,跑在系統內建的 `/usr/bin/python3`(3.9),啟動約 0.15 秒;連不上 LM Studio、超過 15 秒、對齊失敗都回傳原文。
- LM Studio:用到時才載入模型(JIT),閒置 1 小時卸載;伺服器只綁 127.0.0.1。
- 安裝腳本 `setup.sh`、設定腳本 `configure_voiceink.py`、模型比較 `bench.py`。

## 紀錄

- **Xcode 26 沒附 Metal 工具鏈**,VoiceInk 的 mlx-swift 編不過:`xcodebuild -downloadComponent MetalToolchain`(約 690MB)。
- **VoiceInk 初始設定視窗開在另一個螢幕**(筆電本身的螢幕),外接螢幕上看起來像「按了沒反應」。
- **初始設定的模型步驟寫死 Parakeet 或雲端**,沒有跳過按鈕;只能先下載 Parakeet(494MB)過關,之後再改用 Breeze。初始設定建立的模式也寫死 Parakeet + 自動偵測語言。
- **輸出簡體**:VoiceInk 內建的中文 Whisper 提示詞是簡體(見 [../investigations/2026-10-21-traditional-output.md](../investigations/2026-10-21-traditional-output.md))。
- **模式開了 AI 潤稿卻沒作用,也沒任何提示**:
  - 沒指定 Provider 時,退回全域預設的雲端服務(初始設定選的 Groq),沒有金鑰就跳過。
  - 一定要選一個 Prompt 才會潤稿;內建範本要手動加過才算數,新安裝時一個都沒有。
  - 解法:Provider 設 Local CLI、新增一個佔位用的 Prompt(內容 `punct.py` 不會用)。設定要在 VoiceInk 關閉時寫入 UserDefaults,不然它結束時會蓋回去。
- **LM Studio 的設定檔被清空過**(資料夾不見、`settings.json` 是 0 bytes),重新啟動一次就重建。「登入時自動啟動」的選項叫 **Start local LLM service on login**,在設定(⌘,)裡搜尋 login。
- 模型比較和合併邏輯的調整見 [../investigations/2026-10-21-punctuation-model-benchmark.md](../investigations/2026-10-21-punctuation-model-benchmark.md)。

## 為什麼被取代

要裝兩個 App、Python 腳本、LM Studio 要手動開登入啟動,VoiceInk 的設定還有兩個會默默失效的坑。發現 VoiceInk 內建的 Refine 引擎能直接跑 Breeze2 之後,改成 v2。
