# 開發慣例

跟架構決策無關,純粹是「怎麼操作比較順」的約定,寫下來避免每次重新摸索。

## 分支與 remote

- 這是 [Beingpax/VoiceInk](https://github.com/Beingpax/VoiceInk) 的公開 fork(GitHub 規定公開專案的 fork 只能公開),我們的東西都在 **`zhtw` 分支**。
- clone 裡 `origin` = [Jim-Chang/VoiceInk](https://github.com/Jim-Chang/VoiceInk)、`upstream` = 原作者。
- **不會發 PR 回上游**,所以照自己的慣例:文件繁中、放 `docs/`;commit 訊息英文,格式 `area: 說明`(`zhtw:`、`docs:`、`scripts:`),結尾加 `Co-Authored-By`。
- **公開 repo,不放個人資料**:測試案例和文件裡的例句用自己編的,不放實際聽寫內容;實際聽寫的資料放私人 repo:v2 之後的實驗放 `voiceink-zhtw-data`(每個實驗一個資料夾,名稱和 `docs/investigations/` 的文件相同),v1 的補標點評測在 `voiceink-zhtw-lmstudio`。

## 合併上游更新

```bash
scripts/update.sh        # fetch upstream → merge upstream/main → build → 安裝
git push origin zhtw
```

- 用 **merge 不用 rebase**:我們的修改紀錄一直保留,也不用 force push。
- 會衝突的地方:
  - `README.md`:一律保留我們的(`git checkout --ours README.md`)。
  - 改過的上游檔案(清單見 [architecture/README.md](architecture/README.md#修改了原作者的哪些檔案)):手動合併。特別注意:
    - 三個辨識流程(`TranscriptionPipeline`、`AudioFileTranscriptionManager`、`AudioFileTranscriptionService`)在去掉頭尾空白之後呼叫 `ZhTWTranscript.clean` 和 `ZhTWPunctuator.punctuate`;上游改了這段流程,要確認呼叫還在、順序還是在段落格式化和 Word Replacements 之前。`AudioFileTranscriptionManager.startProcessing` 另外包了 `ProcessInfo.beginActivity`(轉檔期間不被 App Nap 降速)。
    - `VoiceInkEngine` 開始錄音時的 `ZhTWPunctuator.preload()` 和 `cleanupResources` 裡的 `unload()`。
    - `project.pbxproj`:sherpa-onnx 的兩個 dylib、CT 模型和搜尋路徑(ID 都以 `E1C7F001` 開頭),和 whisper.xcframework 的設定放在一起;衝突時保留兩邊。
  - 初始設定的 6 個檔案(清單見架構文件):「模型」那一步的本機模型換成 TEA,主要是把 `FluidAudioModel`、`FluidAudioModelManager`、`FluidAudioDownloadStatus` 換成 transcribe.cpp 的型別。上游改了初始設定時,確認「Local」還是 TEA、下載得動。
  - 模型清單的三個檔案(`TranscribeCppModelCatalog`、`TranscriptionModelRegistry`、`LanguageDictionary`)各加了一筆 TEA-ASR-1.1,衝突時保留兩邊。
  - `OfflineTranscribeCppService`:原作者「每 30 秒切一段、逐段辨識」的迴圈我們改了四處:切段改呼叫 `speechAwareChunks`(超過 30 秒、VAD 開著時用 `TranscribeCppSpeechSegmenter`),8 段以上先用 `runBatched` 依長度排序、每 4 段一批辨識完,每段改呼叫 `runGuarded`(鬼打牆時切小重跑、留已辨識的字;批次那條路的停下的段也走同一個 `retryStopped`),接段時 `ZhTWTranscript.needsSpaceBetween`。上游改了這個迴圈,四處都要接回去;我們加的函式都在 `voiceink-zhtw` 註解底下。
  - transcribe.cpp 套件(`project.pbxproj` 的 `XCRemoteSwiftPackageReference "Transcribe-cpp-swift"`、`Package.resolved` 的 `transcribe-cpp-swift`):我們改成自己的 [Jim-Chang/Transcribe-cpp-swift](https://github.com/Jim-Chang/Transcribe-cpp-swift) 0.4.0,套件名稱和原作者的一樣。上游也換版本時取比較新的那個;原作者追上 0.4.0 以後可以換回他的網址。換版本後 TEA 要重新驗證(同一批錄音結果和速度不變),第一次聽寫會多等約 10 秒(重新編譯 Metal 程式);xcodebuild 若報 `module.modulemap has been modified`,把 `.local-build` 裡的 `CTranscribe-*.pcm` 移到垃圾桶再 build。
- 合併後先跑 `scripts/test-punctuation.sh`,再實際聽寫一句,用 `python3 -I scripts/timing_report.py --last 10m` 確認有補標點(`punct` 欄位)、語音辨識用的是 TEA。

## Build

- **第一次**:`make local`(或 `scripts/update.sh --no-pull`)。會在 `~/VoiceInk-Dependencies/` 編 whisper.cpp 的 xcframework(iOS、macOS、visionOS、tvOS 全部,約 10–20 分鐘),Xcode 專案寫死這個路徑,**別刪**。
- **Xcode 26 要另外下載 Metal 工具鏈**:`xcodebuild -downloadComponent MetalToolchain`。沒有的話 mlx-swift 的 `.metal` 檔會編不過。
- `make local` 每次都先刪掉 `.local-build/` 整個重編(暫存約 3.6GB)。**只改幾個檔案時用增量 build**(約 1 分 44 秒),參數照 Makefile 的 `local`:

  ```bash
  ID=$(security find-identity -v -p codesigning | awk '/"Apple Development: / {print $2; exit}')
  xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Release \
    -derivedDataPath .local-build -xcconfig LocalBuild.xcconfig \
    CODE_SIGN_IDENTITY="$ID" CODE_SIGNING_REQUIRED=YES CODE_SIGNING_ALLOWED=YES DEVELOPMENT_TEAM="" \
    CODE_SIGN_ENTITLEMENTS="$PWD/VoiceInk/VoiceInk.local.entitlements" \
    SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) LOCAL_BUILD' \
    -skipPackagePluginValidation -skipMacroValidation build
  ```

  產出在 `.local-build/Build/Products/Release/VoiceInk.app`,關掉 VoiceInk 後用 `ditto` 蓋掉 `/Applications/VoiceInk.app`。
- **簽章**:鑰匙圈裡剛好一張 Apple Development 憑證時,`make local` 會自動用它。簽章固定,重新 build 後麥克風、輔助使用權限不用重給;沒有憑證時用 ad-hoc 簽章,每次 build 後可能要重給。
- 新的 `.swift` 檔放在 `VoiceInk/` 底下會自動加進 App target(Xcode 的 synchronized group),不用改 `project.pbxproj`。

## 從這台幫另一台 Mac 安裝

另一台要先打開「系統設定 → 一般 → 共享 → 遠端登入」,並在旁邊的 ⓘ 打開「允許遠端使用者完整取用磁碟」(不然連線進去讀寫不了「文件」「下載項目」);在這台跑 `ssh-copy-id 帳號@那台.local`(密碼本人輸入)。之後:

- **複製 App(不用編譯)**:`ditto -c -k --keepParent` 打包 → `scp` → 那台 `ditto -x -k` 解到 `/Applications`。這樣複製不會被 Gatekeeper 擋。
- **在那台編譯**:`git clone` 後跑 `scripts/setup.sh`;遠端連線的 PATH 沒有 Homebrew,先 `eval "$(/opt/homebrew/bin/brew shellenv)"`;要跑很久,用 `nohup` 放背景。
- 初始設定(權限、快捷鍵)一定要本人在那台操作;走完後遠端跑 `scripts/setup.sh configure`。

## 查延遲

語音辨識(`asr`、開始錄音時載入 transcribe.cpp 模型的 `asr-prepare`)和補標點的每一段時間都記在系統紀錄(category `ZhTWTiming`,只有時間和數量):

```bash
python3 -I scripts/timing_report.py --last 1h       # 每次聽寫一行
python3 -I scripts/bench/sample_load.py load.tsv 900 # 另開一個終端機:記 15 分鐘的 GPU、CPU 負載
python3 -I scripts/timing_report.py --last 1h --load load.tsv
```

欄位說明在 `scripts/timing_report.py` 開頭。系統紀錄會保留幾天,要更久就把輸出存起來。

轉錄音檔(長錄音)另外有這幾行,也只有時間和數量:`asr-vad`(語音偵測:錄音長度、講話長度、區間數、段數、花多久)、`asr-retry`(哪一段鬼打牆、切小重跑,`at=` 是原始錄音的秒數)、`asr-loop`(切到不到 4 秒還是卡住,留了幾個字)、`asr-chunks`(總段數、`batch=` 每批幾段(1 = 一段一段跑)、重跑幾次、卡住幾段)、`punct ... windows=`(長文字分成幾個視窗補標點)。

```bash
/usr/bin/log show --last 1h --style compact --predicate 'subsystem == "com.prakashjoshipax.voiceink" AND category == "ZhTWTiming"' | grep -E 'asr-(vad|retry|loop|chunks)|windows='
```

## 離線評測工具

`scripts/bench/` 底下是延遲調查用的工具,實際聽寫的內容只放私人 repo `voiceink-zhtw-data`:

| 工具 | 用途 |
|---|---|
| `asr_bench.py` | 用 whisper-cli 以 VoiceInk 的參數跑一批錄音,比較 Breeze-ASR-25 各版本的速度和結果 |
| `punct_ct.py`、`punct-tool.sh` | 專門的標點模型(CT-Transformer,sherpa-onnx)補標點,再用 App 的合併邏輯插回繁體原文 |
| `punct-ct.sh` | 編譯 App 裡同一份 CT 補標點(`ZhTWPunctuator`)成命令列工具,離線跑一批逐字稿;列有 `model` 欄時先照 App 的流程跑 `ZhTWTranscript.clean` |
| `asr_models_run.sh`、`tc_bench.c`、`asr_models.py`、`tea_prepare.py` | 換語音辨識模型的評測:用 transcribe.cpp 跑一批錄音、統計、盲測;`tea_prepare.py` 整理 TEA-ASR 的 tokenizer 再轉 GGUF(見 [investigations/2026-10-22-asr-models.md](investigations/2026-10-22-asr-models.md)) |
| `tea_vocab_run.sh`、`tea_vocab_diff.py`(`tc_bench.c --vocabulary-file`) | TEA 詞彙表的量測:同一批錄音跑舊版 transcribe.cpp、新版、新版加詞彙表,找出兩組結果不同的地方、統計時間和記憶體(見 [plan/2026-10-22-tea-vocabulary.md](plan/2026-10-22-tea-vocabulary.md)) |
| `segment-bench.sh`(`SegmentBench.swift`) | 編譯 App 裡同一份語音偵測切段(`TranscribeCppSpeechSegmenter`),對錄音切段、調參數;只輸出時間和數量,`--wav-dir` 另存切好的每段給 `tc_bench` 辨識 |
| `vad_compare.py` | 語音偵測切段開、關各用 `tc_bench` 辨識一次,逐段比較(見 [plan/2026-10-22-long-audio-segmentation.md](plan/2026-10-22-long-audio-segmentation.md)) |
| `tea_batch_run.sh`、`tea_batch_compare.py`(`tc_bench.c --batch N`) | 批次辨識的量測:每 N 段送一次 `transcribe_run_batch`(`--sort-length` 依長度排序、`--retry-split` 照 App 切兩半重跑),每組一個行程記時間和尖峰記憶體,再和批次 1 比逐字相同的段數;只印統計(見 [plan/2026-10-23-tea-batch.md](plan/2026-10-23-tea-batch.md)) |
| `punct-ct.sh` 的 `[門檻 長度 重疊]` | 長文字分段補標點的視窗大小,調參數用(預設和 App 相同:400、300、40) |
| `sample_load.py` | 每 0.5 秒記 GPU、CPU 負載 |

跑評測時不要同時聽寫,也不要同時跑兩個評測(互搶 GPU,時間會失真)。

`tc_bench` 要和 App 用同一份 transcribe.cpp 時,直接連結 build 下載的 xcframework(`.local-build/SourcePackages/artifacts/transcribe-cpp-swift/CTranscribe/TranscribeCpp.xcframework/macos-arm64_x86_64`,編譯指令在 `tc_bench.c` 開頭);`dr_wav.h` 在 transcribe.cpp 原始碼的 `examples/common/`。

## 測試

- `scripts/test-punctuation.sh`:只編 `ZhTWPunctuation.swift`、`ZhTWTranscript.swift` 加測試程式,跑 `scripts/fixtures/punctuation-cases.json` 和辨識結果整理的案例,不用 build App、不用模型。改合併或整理邏輯時先加案例。
- 簡體專用字對照表(`ZhTWSimplifiedOnly.swift`)由 `python3 -I scripts/gen-zhtw-simplified.py` 產生(OpenCC 固定在 1.1.7),不要手改。
- **聽寫紀錄和錄音只留 3 天**(見架構文件的決策紀錄),要做實驗先複製到私人 repo。
- 實際聽寫的結果在 `~/Library/Application Support/com.prakashjoshipax.VoiceInk/default.store`(SQLite,`ZTRANSCRIPTION` 表):`ZTEXT` 是辨識結果、`ZENHANCEDTEXT` 是補標點後、`ZAIENHANCEMENTMODELNAME`、`ZENHANCEMENTDURATION`、`ZTRANSCRIPTIONDURATION`。查詢指令見 [plan/2026-10-21-v2-single-app.md](plan/2026-10-21-v2-single-app.md#驗證)。
- VoiceInk 的 log 不會留在系統紀錄裡(`log show` 查不到),要看時間就查上面的資料庫。

## 改 VoiceInk 的設定

- 設定存在 UserDefaults 網域 `com.prakashjoshipax.VoiceInk`。模式在 `modeConfigurationsV2`(JSON 的 Data)、中文 Whisper 提示詞在 `CustomLanguagePrompts`。
- **一定要先關掉 VoiceInk 再寫**,不然它結束時會蓋回去。`scripts/setup.sh configure` 會自動關、備份(到 `~/Library/Application Support/com.prakashjoshipax.VoiceInk/zhtw-backups/`)、寫入、再打開。
- 自己的設定值:`ZhTWPunctuationEnabled`(設成 false 暫時關掉補標點,查問題用)。
