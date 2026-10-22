# 在 App 裡下載模型、預設值寫進 App、打包給其他 Mac

2026-10-21。依據 [`../investigations/2026-10-21-in-app-model-download.md`](../investigations/2026-10-21-in-app-model-download.md),這裡不重複推導,只寫要做什麼。

## 背景與目標

[v2](2026-10-21-v2-single-app.md) 換一台 Mac 要裝 Xcode、跑 `scripts/setup.sh` build 和下載模型,初始設定還得先下載用不到的 Parakeet,最後再跑 `scripts/setup.sh configure`。目標:

1. 在這台 build 好、打包成 zip;另一台**不用 Xcode**,解壓縮、打開 App,**在介面上下載兩個模型**就能用。
2. 初始設定只下載 Breeze-ASR-25,不再下載 Parakeet。
3. 初始設定建立的模式直接是 Breeze-ASR-25 + 中文 + VoiceInk Refine,不需要 `setup.sh configure`。
4. 模型仍固定版本:Breeze2-3B 逐檔驗大小和 SHA256(沿用 Refine 下載器);Breeze-ASR-25 用固定 revision 的網址。

## 非目標

- 公證(notarization)、DMG、自動更新:要付費開發者帳號。另一台第一次打開要手動允許。
- 保留原作者的英文 VoiceInk Refine 模型:下載按鈕只下載 Breeze2-3B。
- 驗 Breeze-ASR-25 的 SHA256:VoiceInk 下載 Whisper 模型的流程沒有驗證;固定 revision 的網址內容不會變。
- 補標點模型放進初始設定:初始設定原本沒有 Refine 這一步,加了要改更多原作者的畫面。README 寫明到「AI Models」頁下載。

## 步驟

順序 b → c → a1 → a2 → d,每一步單獨 commit、驗證後再做下一步。

### b. VoiceInk Refine 的下載按鈕改下載 Breeze2-3B

1. `ZhTWPunctuation` 加上 repo(`MXLouis/Llama-Breeze2-3B-Instruct-Text-mlx-4Bit`)、revision(`acaf9551…`)、8 個檔案的大小和 SHA256;拿掉舊位置的 `modelDirectory`、`isInstalled`。
2. `VoiceInkRefineModelDownloader.files` 改用 `ZhTWPunctuation` 的清單。續傳、逐檔驗證、`.voiceink-integrity.json` 都沿用。
3. `VoiceInkRefineService`:`repositoryID`、`pinnedRevision` 改用 `ZhTWPunctuation` 的;指示固定用繁中範例、輸出固定經過 `merge`,拿掉「資料夾存在才啟用」的分支。
4. 模型名稱 `modelName` 從 `VoiceInk Refine V1` 改成 `Breeze2-3B 補標點`,Refine 卡片的說明改成繁中補標點。VoiceInk 每次啟動都會把用 VoiceInk Refine 的模式改成目前的模型名稱(`AIEnhancementService.repairModePromptSelections`),舊設定不會壞;Provider 的名稱 `VoiceInk Refine` 不改(模式設定靠它找到 Provider,改了模式會失效)。`configure_voiceink.py`、`docs/development.md` 跟著改。
5. XPC 引擎每次補標點記錄輸入、輸出 token 數和耗時(不記內容),用來查 v2 紀錄裡 2.47 秒的那一句。
6. 模型位置改成 `~/Library/Application Support/com.prakashjoshipax.VoiceInk/VoiceInkRefine/`(原作者下載器的位置)。這台的舊資料夾 `ZhTWPunctuation/` 在驗證時處理,不寫搬移程式。
7. `scripts/setup.sh` 不再下載補標點模型;`check` 改看新位置。

### c. 預設值寫進 App

1. `WhisperPrompt.languagePrompts["zh"]` 改成繁體句子(和 `configure_voiceink.py` 用的同一句)。
2. `StarterModeFactory`:預設轉錄模型 `ggml-breeze-asr-25-q8_0`、語言 `zh`、AI 潤稿用 VoiceInk Refine。
3. 確認 Refine 模型還沒下載時,模式開著 AI 潤稿不會卡住(應該直接貼沒標點的原文)。

### a1. Breeze-ASR-25 加進內建模型清單

1. `WhisperModel` 加可選的自訂下載網址;沒設的維持原本的 `ggerganov/whisper.cpp`。
2. `TranscriptionModelRegistry` 加 `ggml-breeze-asr-25-q8_0`,網址固定在 `shdennlin/breeze-asr-25-ggml` 的 revision `36c72609…`。
3. 檔名和這台已經匯入的相同:確認清單只出現一筆、顯示已下載。
4. `scripts/setup.sh` 不再下載語音辨識模型。

### a2. 初始設定改成下載 Breeze-ASR-25

1. `OnboardingCoordinator.requiredTranscriptionModel` 改成 Breeze-ASR-25(`WhisperModel`);是否已下載、下載、進度改接 `WhisperModelManager`。
2. `OnboardingFlowController`、`OnboardingView`、`OnboardingModelScreen`、`OnboardingTranscriptionSetupCard`、`TranscriptionModelDownloadCard` 跟著改型別,卡片外觀沿用。
3. 初始設定結束時用 c 的預設值建立模式。

### d. 打包給其他 Mac

1. `scripts/package.sh`:確認 `/Applications/VoiceInk.app` 是這個 fork 的 build(XPC 執行檔裡有 `ZHTW_FEW_SHOT_JSON`),用 `ditto -c -k --keepParent` 打包成 `dist/VoiceInk-zhtw-<日期>-<commit>.zip`(`dist/` 不進 git)。
2. README 加「安裝到其他 Mac」:需求、解壓縮到「應用程式」、第一次打開的 Gatekeeper 允許方式、權限、到哪裡下載兩個模型。原本的 `setup.sh` 流程改成「要自己 build 時」。
3. 更新 [`../architecture/README.md`](../architecture/README.md)(元件位置、改了哪些檔案、決策紀錄、進度)和 [`../development.md`](../development.md)(合併上游時要注意的檔案)。

## 驗證

```bash
scripts/test-punctuation.sh   # 合併邏輯沒被動到
scripts/setup.sh check        # 安裝狀態
```

| 步驟 | 怎麼驗 |
|---|---|
| b | 把 `ZhTWPunctuation/` 移到暫存處 → 打開 App,Refine 卡片顯示未下載、約 2.0GB → 按下載 → `VoiceInkRefine/` 有 8 個檔案和 `.voiceink-integrity.json` → 聽寫有標點、紀錄的 `ZAIENHANCEMENTMODELNAME` 是 `Breeze2-3B 補標點`、模式設定裡的模型名稱已自動更新 → 刪掉暫存處的舊資料夾 |
| c | 讀程式確認;和 a2 一起實測 |
| a1 | 「AI Models → Local」出現 Breeze ASR 25 且顯示已下載;`curl -sIL` 確認固定網址回 200、大小 1656129691 |
| a2 | `defaults export` 備份設定 → 把 ASR 模型移到暫存處、`hasCompletedOnboardingV2` 設為 false → 重跑初始設定:只出現 Breeze-ASR-25,下載完 SHA256 是 `d4b187c4…`,建立的模式是 Breeze + 中文 + VoiceInk Refine → 關掉 VoiceInk、`defaults import` 還原、刪掉暫存檔 |
| d | 解壓縮到暫存資料夾,`codesign --verify --deep`、確認是 arm64;另一台實際安裝時把過程記在下面 |

驗證 b、a2 會重新下載約 3.7GB;改設定前一律關掉 VoiceInk。

## 紀錄

- 2026-10-21 寫 plan。補標點模型:本機那份和 revision `acaf9551` 的 8 個檔案逐一核對過(大檔比 LFS 的 SHA256,小檔比 git blob id),SHA256 直接寫進程式。Breeze-ASR-25 固定在 revision `36c72609`(2026-05-12),q8_0 的 SHA256 和現在用的一致。
- 2026-10-21 暫停:先做延遲調查([../investigations/2026-10-21-latency.md](../investigations/2026-10-21-latency.md))。如果補標點改用專門的標點模型,步驟 b 要改寫。
- 2026-10-22 補標點決定換成 CT-Transformer([2026-10-22-ct-punctuation.md](2026-10-22-ct-punctuation.md)):步驟 b 要改寫,模型內建進 App 就拿掉,在 App 內下載就改成下載 CT 的模型(還沒決定,傾向內建);步驟 c 的預設模式不再開 AI 潤稿。換完 CT 再接著做,開始前先改寫這份計畫。
