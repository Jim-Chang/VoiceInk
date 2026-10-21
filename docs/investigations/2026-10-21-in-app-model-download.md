# 在 App 裡下載模型、預設值寫進 App、打包給其他 Mac

2026-10-21。背景:v2 完成後,換一台 Mac 仍要跑 `scripts/setup.sh` 下載兩個模型、初始設定時先下載用不到的 Parakeet、最後再跑 `scripts/setup.sh configure` 寫設定。目標是:**在一台 Mac build 好、打包成 zip,另一台(不用裝 Xcode)解壓縮後,打開 App 在介面上就能下載模型、直接可用。**

## 現況

| 項目 | 現在怎麼做 | 為什麼 App 介面做不到 |
|---|---|---|
| 語音辨識模型 Breeze-ASR-25 | `setup.sh` 下載到 `WhisperModels/` | 內建模型清單沒有它;`WhisperModel.downloadURL` 寫死 `ggerganov/whisper.cpp` |
| 補標點模型 Breeze2-3B | `setup.sh` 下載到 `ZhTWPunctuation/` | VoiceInk Refine 的下載按鈕寫死下載原作者的英文模型 |
| 初始設定 | 只能下載 Parakeet(或接雲端)才能過關 | `OnboardingCoordinator.requiredTranscriptionModel` 寫死 `parakeet-tdt-0.6b-v3` |
| 預設值 | `setup.sh configure` 改 UserDefaults | 中文提示詞內建是簡體;初始設定建立的模式寫死 Parakeet + 自動偵測 |

## 各項評估

### a1. Breeze-ASR-25 加進內建模型清單(小)

- `TranscriptionModelRegistry` 的 `WhisperModel` 加一個可選的自訂下載網址;沒設的維持原本的 `ggerganov/whisper.cpp`。
- 加一筆 `ggml-breeze-asr-25-q8_0`,網址固定在 `shdennlin/breeze-asr-25-ggml` 的某個 revision。
- 名稱含 `q8`,VoiceInk 會自動跳過 Core ML 編碼器的下載(`WhisperModelFile.coreMLZipDownloadURL`)。
- VoiceInk 下載 Whisper 模型不驗 SHA256;用固定 revision 的網址,內容不會變。
- 改動:`TranscriptionModel.swift`、`TranscriptionModelRegistry.swift`,約 20 行。

### a2. 初始設定改成下載 Breeze-ASR-25(中)

- Parakeet 綁在 6 個檔案:`OnboardingCoordinator`、`OnboardingFlowController`、`OnboardingView`、`OnboardingModelScreen`、`OnboardingTranscriptionSetupCard`、`TranscriptionModelDownloadCard`。型別都是 `FluidAudioModel`,下載進度用 `FluidAudioModelManager.downloadStatus`;Breeze 是 `WhisperModel`,進度在 `WhisperModelManager.downloadProgress`。
- 做法:把「必要模型」改成 Breeze-ASR-25,下載、進度、是否已下載改接 `WhisperModelManager`。卡片的介面(標題、大小、進度條)沿用。
- 風險:原作者改初始設定時,合併會在這幾個檔案衝突。

### b. VoiceInk Refine 的下載按鈕改下載 Breeze2-3B(中)

- `VoiceInkRefineModelDownloader`(950 行)支援續傳、逐檔驗大小與 SHA256、驗證紀錄(`.voiceink-integrity.json`),但檔案清單 `files`、repo、revision 都寫死成原作者的模型。
- 做法:清單、repo、revision 改由 `ZhTWPunctuation` 提供(Breeze2-3B 的 8 個檔案、大小、SHA256,固定 revision `acaf9551…`);模型改放在下載器的 snapshot 資料夾,`ZhTWPunctuation.modelDirectory` 改指過去,完整性檢查直接沿用。
- Refine 的卡片會顯示我們的模型大小;名稱、說明可以順便改成「繁中補標點(Breeze2-3B)」。
- 這台 Mac 已經有的模型:搬到新位置,或第一次啟動時偵測舊位置。
- 改動:`VoiceInkRefineModelDownloader.swift`、`VoiceInkRefineService.swift`、`ZhTWPunctuation.swift`,可能加上 Refine 卡片的文字。

### c. 預設值寫進 App(小)

- `WhisperPrompt.languagePrompts["zh"]` 改成繁體句子。
- `StarterModeFactory`:預設轉錄模型改 Breeze-ASR-25、語言 `zh`、AI 潤稿用 VoiceInk Refine。
- 做完 a2、b、c,`configure_voiceink.py` 就不需要了(保留給已經裝過的 Mac 修正設定用)。

### d. 打包給其他 Mac(小)

- `scripts/package.sh`:用 `ditto -c -k --keepParent` 把 `/Applications/VoiceInk.app` 打包成 `VoiceInk-zhtw-<日期>-<commit>.zip`。
- 另一台的條件:Apple Silicon、16GB 以上、macOS 15 以上(`LSMinimumSystemVersion`)。App 只有 arm64。
- App 用 Apple Development 憑證簽章、沒有公證(要付費開發者帳號)。第一次打開會被 Gatekeeper 擋:系統設定 → 隱私權與安全性 →「強制打開」;或 `xattr -dr com.apple.quarantine /Applications/VoiceInk.app`。
- 麥克風、輔助使用權限在新 Mac 要點一次。之後用同一張憑證 build 的新版,權限通常不用重給。
- 這台沒辦法驗證另一台的實際狀況,第一次要記錄在 plan 裡。

## 對上游合併的影響

做完後改到的上游檔案從 4 個變成約 12 個(多了初始設定的 6 個、模型清單 2 個、下載器、`WhisperPrompt`、`StarterModeFactory`)。不回饋上游,所以可以接受;衝突時以「我們的行為」為準,記在 [../development.md](../development.md)。

## 建議

全部做,順序:**b → c → a1 → a2 → d**。每一步都能單獨驗證:

| 步驟 | 驗證方式 |
|---|---|
| b | 把現有的 Breeze2 資料夾搬開 → 在 Refine 卡片按下載 → 聽寫有標點 |
| c | 讀程式即可確認;a2 做完後用新的初始設定一起驗 |
| a1 | 把 Breeze-ASR 檔案搬開 → 在「AI Models → Local」按下載 → 聽寫正常 |
| a2 | 備份設定後把 `hasCompletedOnboardingV2` 設回 false → 重跑初始設定,只下載 Breeze-ASR 就能過關 |
| d | 這台解壓縮到暫存資料夾確認能開;另一台實際安裝時記錄 |

驗證 b、a1 會重新下載約 3.7GB;驗證 a2 會動到這台的設定,先備份,驗完還原。
