# v2:單一 App(VoiceInk Refine 跑 Breeze2-3B)

2026-10-21。依據 [`../investigations/2026-10-21-single-app-via-refine.md`](../investigations/2026-10-21-single-app-via-refine.md),這裡不重複推導,只寫要做什麼。

## 背景與目標

取代 [v1](2026-10-21-v1-lmstudio-two-apps.md) 的 LM Studio + Python 腳本。目標:

1. 只剩 VoiceInk 一個 App,不需要 LM Studio、Python、背景伺服器、開機自動啟動。
2. 補標點的效果和 v1 一樣:一定繁體、不改字、出錯就貼原文。
3. 模型已載入時,補標點不超過 1 秒。

## 非目標

- 不改 VoiceInk 的介面(這一版)。模型下載、預設值仍由 `scripts/setup.sh` 處理;改成在 App 內下載是下一個 plan。
- 不保留原作者的英文 VoiceInk Refine:裝了 Breeze2 時 Refine 就是繁中補標點。

## 步驟

1. GitHub fork `Beingpax/VoiceInk` → `Jim-Chang/VoiceInk`,建 `zhtw` 分支。
2. 新增 `VoiceInk/Features/ZhTW/ZhTWPunctuation.swift`:模型位置、繁中指示、範例、合併邏輯(從 v1 的 `punct.py` 移植)。
3. `VoiceInkRefineService`:Breeze2 資料夾存在時改用它的路徑和指示,輸出後合併。
4. `VoiceInkRefineInferenceEngine`(XPC):`ZHTW_FEW_SHOT_JSON:` 前綴的指示展開成多輪對話,temperature 0。
5. 把 Breeze2-3B(MLX 4bit)放到 `~/Library/Application Support/com.prakashjoshipax.VoiceInk/ZhTWPunctuation/Llama-Breeze2-3B-Instruct-Text-mlx-4Bit/`。
6. build、安裝,模式的潤稿 Provider 改成 VoiceInk Refine(`selectedAIProvider = "VoiceInk Refine"`、`selectedAIModel = "VoiceInk Refine V1"`)。
7. 關掉 LM Studio 伺服器,實際聽寫驗證(紀錄的 `ZAIENHANCEMENTMODELNAME` 要是 `VoiceInk Refine V1`)。
8. `VoiceInkRefineXPCClient`:閒置卸載時間改成可設定,預設 5 分鐘。
9. 腳本(`scripts/setup.sh`、`update.sh`、`configure_voiceink.py`、`test-punctuation.sh`)和文件。

## 驗證

```bash
scripts/test-punctuation.sh   # 合併邏輯,12 個案例
scripts/setup.sh check        # 安裝狀態
```

實際聽寫後查紀錄:

```bash
sqlite3 -readonly ~/Library/Application\ Support/com.prakashjoshipax.VoiceInk/default.store \
  "select datetime(ZTIMESTAMP+978307200,'unixepoch','localtime'), ZAIENHANCEMENTMODELNAME,
          round(ZENHANCEMENTDURATION,2), ZTEXT, ZENHANCEDTEXT
   from ZTRANSCRIPTION order by ZTIMESTAMP desc limit 5;"
```

## 紀錄

- 2026-10-21 步驟 1–7 完成。合併邏輯的 Swift 版和 Python 版用 24 個案例比對,結果完全一致。build 一次通過(只改幾個檔案時用增量 build 約 1 分 44 秒,見 [../development.md](../development.md))。
- 2026-10-21 實際聽寫(LM Studio 已關閉):全部由 `VoiceInk Refine V1` 補上標點、字沒被改。模型已載入時 0.78–0.83 秒;閒置 10 秒被卸載後的第一句 2.65–2.82 秒(錄音 3.9–7 秒,不夠在背景載完)。
- 2026-10-21 步驟 8:卸載時間改成 5 分鐘(`ZhTWRefineKeepWarmSeconds` 可調)。待確認:隔 1–2 分鐘再講的第一句也是約 0.8 秒。
- 2026-10-21 步驟 9 完成;fork 推上 GitHub。v1 的私人 repo 改名為 `voiceink-zhtw-lmstudio`。
