# 換語音辨識模型:能不能更快、直接有標點

2026-10-22 開始。這份先寫好「為什麼做」和「實驗設計」再跑實驗,結果依日期往下加;看完結果才加的測試標「追加」。含實際聽寫內容的原始輸出放在私人 repo `voiceink-zhtw-data` 的 `2026-10-22-asr-models/`,這裡只放統計數字。

## 為什麼做

- 延遲調查([2026-10-21-latency.md](2026-10-21-latency.md) 實驗 B)的結論:Breeze-ASR-25 q8_0 + Metal 短句約 1.2 秒是下限。q5、q4、Core ML、只處理實際長度都不行。原因是 Whisper 的編碼器不管講多短都處理一整段 30 秒的音訊(短句 1.2 秒裡編碼器佔 0.86 秒)。
- 補標點換成 CT-Transformer 之後只要幾毫秒([../plan/2026-10-22-ct-punctuation.md](../plan/2026-10-22-ct-punctuation.md)),等待時間的大部分就是語音辨識。
- 2026 年出了幾個不是 Whisper 架構的模型:編碼器只處理實際的長度,有的直接輸出標點,有的直接輸出繁體。

要回答四個問題:

1. 換掉 Breeze 能不能更快?
2. 準確度、英文詞、繁體會不會變差?
3. 模型自己輸出的標點能不能取代 CT-Transformer?
4. 放進 VoiceInk 要多少工作?

## 候選

| 代號 | 模型 | 架構 | 輸出 | 授權 |
|---|---|---|---|---|
| `breeze`(對照組) | [Breeze-ASR-25](https://huggingface.co/MediaTek-Research/Breeze-ASR-25) q8_0,現在用的 | Whisper large-v2 微調 | 繁體、沒標點 | Apache-2.0 |
| `tea` | [TEA-ASR-1.1](https://huggingface.co/JacobLinCool/TEA-ASR-1.1)(2B) | Qwen3-ASR-1.7B + LoRA,改過 tokenizer | 繁體、台灣用詞 | MIT(基底 Apache-2.0) |
| `tea-mini` | [TEA-ASR-1.1-mini](https://huggingface.co/JacobLinCool/TEA-ASR-1.1-mini)(0.78B) | Qwen3-ASR-0.6B + LoRA,改過 tokenizer | 繁體、台灣用詞 | MIT(基底 Apache-2.0) |
| `qwen` | [Qwen3-ASR-1.7B](https://huggingface.co/Qwen/Qwen3-ASR-1.7B)(2026-01,阿里) | 音訊編碼器 + Qwen3 語言模型,逐字產生 | 簡體、有標點 | Apache-2.0 |
| `qwen-mini` | [Qwen3-ASR-0.6B](https://huggingface.co/Qwen/Qwen3-ASR-0.6B) | 同上,較小 | 簡體、有標點 | Apache-2.0 |
| `sensevoice` | [SenseVoice-Small](https://huggingface.co/FunAudioLLM/SenseVoiceSmall)(阿里) | 非自回歸(CTC),一次輸出整段 | 簡體,開 ITN 才有標點 | FunASR 模型授權(要標示出處、保留模型名稱) |
| `funasr-nano`(順便) | [Fun-ASR-Nano-2512](https://huggingface.co/FunAudioLLM/Fun-ASR-Nano-2512)(阿里) | SenseVoice 編碼器 + Qwen3-0.6B 語言模型 | 簡體,開 ITN 才有標點 | model card 寫 Apache-2.0,GGUF 轉檔者標 FunASR 模型授權 1.1;以較嚴的為準 |

不測:Luigi/Qwen3-ASR-Micro(Hugging Face 回 401,私人或已刪除)。

TEA-ASR 作者自己量的混合錯誤率(MER,越低越好;評分前都轉成簡體、去掉標點,所以看不出繁體和標點的差別):

| | TEA-ASR-1.1 | TEA-1.1-mini | Qwen3-ASR-1.7B | Qwen3-ASR-0.6B | Breeze-ASR-25 |
|---|---|---|---|---|---|
| CommonVoice 19 zh-TW(朗讀) | 3.58 | 5.12 | 3.90 | 5.79 | 8.03 |
| ASCEND(中英夾雜對話) | 9.60 | 11.20 | 10.57 | 12.54 | 17.53 |
| CSZS(中英夾雜) | 10.94 | 12.51 | 11.03 | 16.03 | 12.18 |
| NTUML2021(上課錄音) | 6.67 | 7.53 | 10.12 | 11.03 | 7.50 |

這些是公開資料集,和使用者的聽寫(口語、給 Claude Code 的指令、中英夾雜的技術詞)不一樣,速度和標點也沒有公布,所以要自己量。

## 事先查到的

- **VoiceInk 上游已經內建 [transcribe.cpp](https://github.com/handy-computer/transcribe.cpp)**(套件 `Transcribe-cpp-swift` 0.2.0-dev.856d7c1,ggml + Metal,MIT),用來跑 Cohere Transcribe 和 SenseVoice Small(`TranscribeCppModelCatalog.swift`:SenseVoice 用 Q8_0、開 ITN、每 30 秒切一段)。這個版本的 transcribe.cpp 也支援 Qwen3-ASR 0.6B / 1.7B 和 Fun-ASR-Nano,有官方轉好的 GGUF。所以 Qwen3-ASR 類的模型很可能只要在模型清單加一筆。
- **TEA-ASR 只提供 safetensors**(給 `qwen-asr` 套件用)。繁體是靠改過的 tokenizer:把部分 token 的文字換成繁體,換完撞名的加上私用區字元(U+E000–U+F8FF),解碼後再刪掉。要放進 transcribe.cpp 得自己轉 GGUF,輸出也要刪掉私用區字元(或轉檔時先處理掉)。
- **sherpa-onnx 1.13.8**(CT 計畫要加進 App 的)也支援 Qwen3-ASR(int8,CPU)和 SenseVoice;TEA 要自己匯出 ONNX。
- **MLX**:[mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift) 支援 Qwen3-ASR;VoiceInk 已經有 mlx-swift(VoiceInk Refine 在用)。
- **whisper.cpp** 只能跑 Whisper 架構,這次的候選都不行。

## 實驗設計

### 資料

延遲調查用的 91 段實際聽寫錄音(私人 repo `2026-10-21-latency/recordings/`,5 秒以下 51 段、5–20 秒 28 段、20 秒以上 12 段,最長 108 秒)。

### 跑法

- **Breeze**:沿用實驗 B 的 `whisper-cli` 和參數(和 App 相同:中文、繁體提示詞、temperature 0.2、best_of 5、flash attention、silero VAD),每段各開一次程式,辨識時間 = 總時間 − 載入時間。同一天重跑,速度才能和其他模型比。
- **其他模型**:用 transcribe.cpp 的 C API 寫一支小程式(`scripts/bench/tc_bench.c`):載入模型一次、用第一段暖機,然後逐段呼叫 `transcribe_run`,記每段花的時間。和 App 一樣,載入藏在錄音期間,不算進辨識時間。
  - transcribe.cpp 用 VoiceInk 鎖定的同一個 commit(`856d7c1`)編譯,Metal。
  - 語言指定中文(`zh`,等同 `qwen-asr` 的 `language="Chinese"`);SenseVoice、Fun-ASR-Nano 開 ITN(才有標點,VoiceInk 對 SenseVoice 也是開的)。
  - 不加 VAD(VoiceInk 的 transcribe.cpp 路徑也沒有)。切段照 VoiceInk 的做法(在最後幾秒找最安靜的地方切):SenseVoice 每段最多 30 秒(和 VoiceInk 的設定相同);其他模型整段一次辨識(Qwen3-ASR 一次可處理約 87 分鐘)。
- **量化**:都用 Q8_0(和現在的 Breeze 一樣)。Qwen3-ASR、SenseVoice、Fun-ASR-Nano 用 transcribe.cpp 官方轉好的 GGUF。TEA 用 transcribe.cpp 的轉檔程式自己轉:先把 `tokenizer.json` 拆成轉檔程式要的 `vocab.json` + `merges.txt`,再量化成 Q8_0;輸出刪掉私用區字元。
- **TEA 轉檔正確性**:自己轉的 GGUF 和官方 `qwen-asr` 套件(PyTorch)各跑 20 段(短中長都有),比對輸出。差很多就先找原因,不進評測。
- **記憶體**:每個模型跑完記 `/usr/bin/time -l` 的 peak memory footprint。
- 跑的時候不聽寫、不跑其他評測、接電源,一個模型跑完再跑下一個。
- 檔案大小、授權、放進 App 的方式由文件和程式碼查。

### 指標

1. **速度**:辨識時間的中位數和最大值,分短(5 秒以下)、中(5–20 秒)、長(20 秒以上);載入時間另記。
2. **準確度**(沒有標準答案,用盲評;Breeze f16 會偏向 Breeze,不能當跨模型的答案):
   - 先算每個候選和 Breeze 差多少(去標點、轉簡體、英文轉小寫後的字元差異率)。只代表「不一樣」,不代表誰對。
   - **Sonnet 子代理盲評**:每段把各模型的結果(去標點;簡體的先用 OpenCC s2twp 轉成繁體,也就是會貼出來的樣子;完全相同的合併成一個)隨機標成 A、B、C…,對照表另存、不讓它讀。每個版本標「沒錯 / 小錯(同音字、語助詞,不影響理解)/ 意思錯」,再選最好的。Sonnet 聽不到聲音,只能從通不通順判斷,所以只當初篩。
   - **使用者盲測**(要聽錄音):約 12 段,短中長都有,挑各模型結果不同的。每段給 Breeze 和 Sonnet 評最好的兩個候選(隨機排序),選最接近講的內容(可並列)。
   - 如果盲測分不出來,再請使用者把約 20 段改成正確的句子當標準答案,算真正的錯誤率(要先問)。
3. **英文詞**:每個模型輸出的英文字數。Breeze 或任一候選有英文的段落,逐段看英文是被保留、翻成中文,還是變成音譯(Sonnet 初篩,Claude 複核)。
4. **繁體**:
   - 簡體輸出的模型用 OpenCC s2twp 轉。找出「轉成簡體後一樣、繁體卻和原生繁體模型(Breeze、TEA)不同」的字,例如 后/後、只/隻、干/乾/幹、里/裡、台/臺,逐個判斷是不是轉錯,統計轉錯的字數。
   - 原生繁體的模型(Breeze、TEA)統計有沒有夾雜簡體字。
5. **標點**(模型自己輸出的):
   - 統計:有標點的段落比例;有句號、問號或驚嘆號(App 會因此跳過 CT)的段落比例;每 100 字幾個標點;全形還是半形。
   - **和 CT 比**:同一個候選的文字,一邊是它自己的標點,一邊是去掉標點後用 CT-Transformer int8 補(和 App 計畫的做法相同)。字完全一樣,只差標點。Sonnet 盲評(A/B 每題隨機),再挑約 8 題給使用者(不用聽錄音)。
6. **模型大小、記憶體、授權、放進 VoiceInk 的方式**(transcribe.cpp / sherpa-onnx / MLX Swift / whisper.cpp)。

### 事先的假設

1. **速度**:Qwen3-ASR 類的編碼器只處理實際長度,短句會比 Breeze 的 1.2 秒快很多(0.6B 約 0.5 秒內、1.7B 約 0.8 秒內)。長句差距變小;1.7B 的語言模型比 Breeze 的解碼器大,長句可能一樣或更慢。
2. **SenseVoice** 不是逐字產生,各種長度都最快,但台灣用語、中英夾雜比較差,還要簡轉繁。
3. **準確度**:TEA-ASR-1.1 ≥ Breeze(作者的數字),TEA-mini 約等於 Breeze。Qwen 基底的內容和 TEA 接近,但轉繁體會有少數錯字,中英夾雜時偶爾把整句翻成英文(TEA 作者提到的問題)。
4. **標點**:Qwen3-ASR 類直接輸出標點,品質和 CT 差不多。果真如此,App 遇到有句號的結果本來就會跳過 CT,不用改程式。
5. **放進 App**:Qwen3-ASR、TEA 走 VoiceInk 已經有的 transcribe.cpp,在模型清單加一筆即可;TEA 另外要自己轉 GGUF、處理私用區字元、找地方放檔案。

### 判斷標準(事先訂)

建議換模型要同時符合:

- 短句辨識中位數比 Breeze 快 0.4 秒以上;長句中位數不能慢超過 20%。
- 使用者盲測不比 Breeze 差(較好的題數 ≥ 較差的題數)。
- 英文詞保留不比 Breeze 差。
- 繁體:模型原生繁體,或 s2twp 轉錯每 1000 字不超過 1 個。
- 記憶體不超過 Breeze(實測)。

標點:使用者盲測裡模型自己的標點不比 CT 差,才建議讓它取代 CT;否則維持 CT(App 要改成先去掉模型的標點再補,因為現在的規則是「已有句號就不補」)。

這次只調查和評測,不改 App 的程式;換不換由使用者看完結果決定。

## 結果(2026-10-22)

M1 Pro 32GB,接電源。原始輸出在私人 repo 的 `2026-10-22-asr-models/`(README 列了每個檔案)。程式在 `scripts/bench/`:`tc_bench.c`(用 transcribe.cpp 量每段的時間)、`asr_models_run.sh`(依序跑每個模型)、`tea_prepare.py`(TEA 轉 GGUF 前整理 tokenizer)、`tea_reference.py`(官方 qwen-asr 對照)、`asr_models.py`(整理結果、統計、盲評題目)。

### 跑的過程

- **兩輪**:第一輪有三段被干擾(11:24 另一個 session build 並重開 VoiceInk、11:28 使用者聽寫一句、11:30 另一個 session 跑 CT 測試),所以 7 個模型整輪重跑。第二輪 11:36 VoiceInk 又被重開一次(App 啟動和預熱 Breeze 約 5 秒)。兩輪的辨識文字 7 個模型都**逐字相同**,時間中位數差 2% 以內;下面的時間每段取兩輪中較快的一次(干擾只會讓時間變長)。
- **對照組可信**:Breeze 的結果和昨天實驗 B 逐字相同,時間差 1% 以內。
- **TEA 轉檔正確**:自己轉的 GGUF(整段辨識)和官方 `qwen-asr`(PyTorch、fp32)各跑 20 段:TEA-mini 17 段逐字相同、2 段差 1–4 處;TEA 16 段相同、3 段差 1–6 處(Q8 量化的數值差異,例如多一個「看」、「嗎?」變「嘛,」)。私用區字元刪掉後和官方輸出一致。兩個模型各有 1 段是下面的產生上限造成失敗。
- **追加:每次最多 256 個 token。** VoiceInk 鎖定的 transcribe.cpp(`856d7c1`,2026-08)裡,Qwen3-ASR 和 Fun-ASR-Nano 每次最多產生 256 個 token。108 秒(約 580 字)那段 5 個模型都失敗、回傳空白;在 App 裡會變成整段辨識失敗。transcribe.cpp 2026-09 的版本(#165)已改成依音訊長度調整。追加的做法:和 VoiceInk 對 SenseVoice 的設定一樣,每 30 秒切一段,重跑 30 秒以上的 10 段(也跑兩輪,文字相同),91 段全部成功。**下面 Qwen3-ASR 類和 Fun-ASR-Nano 30 秒以上的錄音都用切段的結果**(切段後文字和整段辨識不完全相同,時間差不多)。

### 速度

辨識時間(秒,中位數 / 最大;不含載入):

| | 短(51 段) | 中(28 段) | 長(12 段) | 91 段合計 | 載入 |
|---|---|---|---|---|---|
| Breeze q8_0(現在) | 1.20 / 1.49 | 1.80 / 2.74 | 4.82 / 14.72 | 179.9 | 0.51 |
| TEA-ASR-1.1 | 0.21 / 0.36 | 0.62 / 1.20 | 2.24 / 6.92 | 63.7 | 0.96 |
| TEA-ASR-1.1-mini | 0.13 / 0.22 | 0.39 / 0.84 | 1.44 / 5.17 | 41.7 | 0.46 |
| Qwen3-ASR-1.7B | 0.23 / 0.40 | 0.68 / 1.40 | 2.56 / 7.85 | 69.9 | 0.96 |
| Qwen3-ASR-0.6B | 0.15 / 0.25 | 0.39 / 0.84 | 1.52 / 5.13 | 43.4 | 0.45 |
| SenseVoice-Small | 0.05 / 0.07 | 0.12 / 0.22 | 0.40 / 1.16 | 11.8 | 0.16 |
| Fun-ASR-Nano | 0.15 / 0.26 | 0.38 / 0.80 | 1.61 / 4.78 | 41.7 | 0.47 |

- 短句 Breeze 的 1.2 秒裡編碼器佔約 0.86 秒;TEA 的編碼器只要 0.03 秒(只處理實際長度),剩下是逐字產生(0.15 秒)。
- 不只短句,中、長句也快 2–3 倍。
- SenseVoice 第一次載入要 9.9 秒(Metal 第一次編譯,之後 0.16 秒);App 在錄音開始時載入,只有第一次會感覺到。

### 準確度(Sonnet 初篩)

91 段裡 6 段 7 個模型完全相同,其餘 85 段給 Sonnet 盲評(私人 repo 的 `R-sonnet.json`、`R-unblinded.json`)。每個模型在這 85 段裡的判斷:

| | 沒錯 | 小錯 | 意思錯 | 評為最好 | 和 Breeze 的字元差異 |
|---|---|---|---|---|---|
| Breeze | 34 | 22 | 29 | 38 | — |
| TEA-ASR-1.1 | 43 | 19 | 23 | 50 | 12.3% |
| TEA-ASR-1.1-mini | 43 | 16 | 26 | 44 | 12.6% |
| Qwen3-ASR-1.7B | 43 | 17 | 25 | 49 | 12.6% |
| Qwen3-ASR-0.6B | 37 | 19 | 29 | 41 | 13.5% |
| SenseVoice-Small | 21 | 19 | 45 | 21 | 16.4% |
| Fun-ASR-Nano | 36 | 22 | 27 | 44 | 13.9% |

- 差異多半是語助詞(呃、好)、嗎/嘛、他/牠、同音字;長句(20 秒以上)每個模型都至少錯一處,Sonnet 幾乎都判「意思錯」。
- 短句(45 段有差異)「沒錯」:Breeze 28、TEA 33、TEA-mini 34、Qwen-1.7B 31、Qwen-0.6B 28、SenseVoice 16、Fun-ASR-Nano 28。
- Sonnet 聽不到錄音,只能看通不通順;以使用者盲測為準(見下)。

### 英文詞

29 段有英文詞(任一版本)。Sonnet 逐段標每個版本的英文:

| | 照原樣 | 拼錯 | 變成中文 | 漏掉 | 輸出的英文字數(91 段) |
|---|---|---|---|---|---|
| Breeze | 16 | 10 | 2 | 1 | 101 |
| TEA-ASR-1.1 | 16 | 9 | 4 | 0 | 104 |
| TEA-ASR-1.1-mini | 14 | 12 | 3 | 0 | 106 |
| Qwen3-ASR-1.7B | 15 | 7 | 7 | 0 | 96 |
| Qwen3-ASR-0.6B | 11 | 7 | 11 | 0 | 91 |
| SenseVoice-Small | 5 | 13 | 5 | 6 | 70 |
| Fun-ASR-Nano | 10 | 11 | 6 | 2 | 102 |

TEA 和 Breeze 差不多;原版 Qwen3-ASR 比較常把英文詞寫成中文(TEA 作者說的問題),0.6B 更明顯;SenseVoice 最差。

### 繁體

- **原生繁體(Breeze、TEA)**:Breeze 沒有簡體字。TEA 偶爾漏出簡體字:TEA-1.1 4 個(记、标、诶 2 次)、TEA-mini 7 個(例如这、还、来,都是 TEA 的 tokenizer 沒對應到的字),另外 TEA-1.1 用了 5 次異體字「爲」、1 次把「斗」寫成「鬥」。以 91 段約 4200 個中文字算,TEA-1.1 每 1000 字 0.9 個、TEA-mini 1.7 個。
- **簡轉繁(Qwen3-ASR、SenseVoice、Fun-ASR-Nano,OpenCC s2twp)**:
  - 逐字轉錯很少:每個模型 1 個(「餵」轉成「喂」);SenseVoice 另外 2 個(週/周、裡/里,前後字本身就辨識錯)。量詞「台」都轉成「臺」(5 次,教育部標準字,不算錯,但和平常寫法不同)。
  - **s2twp 的台灣用詞轉換會改掉講的詞**。以 Qwen3-ASR-1.7B 為例 11 處:對的「登錄→登入」3 處;改掉原本講法的「文件→檔案」4 處、「腳本→指令碼」1、「高級→高階」1、「設置→設定」1;「設備→裝置」1(這處本來就辨識錯)。0.6B 13 處、SenseVoice 10 處、Fun-ASR-Nano 8 處,同樣以「文件→檔案」最多。
  - 把「改成沒講的詞」算轉錯,Qwen3-ASR-1.7B 每 1000 字約 1.9 個(1 個字 + 7 個詞),超過事先訂的 1 個。改用 s2tw(只轉字、不轉詞)可避開這些,但會留下大陸用詞(例如登錄)。

### 標點

| | 有標點的段落 | 有句號/問號/驚嘆號的段落(App 會跳過 CT) | 每 100 個中文字幾個標點 |
|---|---|---|---|
| Breeze | 5 | 0 | 0.1 |
| TEA-ASR-1.1 | 22 | 18 | 1.3 |
| TEA-ASR-1.1-mini | 22 | 12 | 1.5 |
| Qwen3-ASR-1.7B | 91 | 91 | 11.6 |
| Qwen3-ASR-0.6B | 91 | 91 | 12.0 |
| SenseVoice-Small | 91 | 91 | 9.9 |
| Fun-ASR-Nano | 82 | 82 | 10.6 |
| (參考)CT 補 Breeze 的結果 | 91 | 91 | 11.0 |

- **TEA 幾乎不加標點**(推測微調資料沒有標點;TEA-mini 跑英文的公開範例也是全小寫、沒標點)。偶爾加的也很零星,例如 175 字只有 4 個。照 App 現在的規則(已有句號就不補),這 12–18 段會跳過 CT、只剩零星標點,所以**換 TEA 要改成先去掉標點再一律用 CT 補**。
- **Qwen3-ASR 自己的標點**:每段都有,全形,密度和 CT 差不多,問號比較多(70 個 vs CT 47 個)。同一份 Qwen-1.7B 的文字,自己的標點和「去掉後用 CT 補」有 50 段不同,Sonnet 盲評:Qwen 自己的 30 段較好、CT 10 段、差不多 10 段。以使用者盲測為準(見下)。

### 模型大小、記憶體

| | 檔案大小 | 記憶體(peak footprint) |
|---|---|---|
| Breeze q8_0 | 1.66GB | 2.73GB |
| TEA-ASR-1.1 Q8_0 | 2.18GB | 3.69GB |
| TEA-ASR-1.1-mini Q8_0 | 0.85GB | 1.60GB |
| Qwen3-ASR-1.7B Q8_0 | 2.19GB | 3.69GB |
| Qwen3-ASR-0.6B Q8_0 | 0.85GB | 1.61GB |
| SenseVoice-Small Q8_0 | 0.25GB | 0.70GB |
| Fun-ASR-Nano Q8_0 | 0.89GB | 1.63GB |

這版 transcribe.cpp 把權重複製進記憶體;2026-10-20 的版本改成 mmap(#195),新版可能更省,沒量。

### 放進 VoiceInk

| 方式 | 現況 | Qwen3-ASR | TEA-ASR | SenseVoice |
|---|---|---|---|---|
| **transcribe.cpp(GGUF,Metal)** | 已在 App 裡(`TranscribeCppModelCatalog`) | 模型清單加一筆,用官方 GGUF;要每 30 秒切段,或更新 transcribe.cpp 到 2026-09 之後 | 同左,另外要自己轉 GGUF(這次的做法)、找地方放檔案、輸出刪掉私用區字元(或轉檔時先拿掉) | 已經在模型清單,可以直接在 App 裡試 |
| sherpa-onnx(ONNX,CPU) | CT 計畫會加進 App | 有 int8 版 | 要自己匯出 ONNX | 有 |
| MLX Swift | App 有 mlx-swift(VoiceInk Refine 用) | mlx-audio-swift 有,要加新套件 | tokenizer 的 Replace 解碼器要確認 swift-transformers 支援 | — |
| whisper.cpp | 現在的 Breeze | 不行 | 不行 | 不行 |

transcribe.cpp 路徑在 App 裡會用模型設定的語言(中文 → `language Chinese`),和這次評測相同。

### 授權

| | 授權 | 備註 |
|---|---|---|
| Breeze-ASR-25 | Apache-2.0 | |
| TEA-ASR-1.1 / mini | MIT | 基底 Qwen3-ASR 是 Apache-2.0,要附它的授權和 NOTICE |
| Qwen3-ASR | Apache-2.0 | |
| SenseVoice-Small、Fun-ASR-Nano | FunASR 模型授權 1.1 | 可以使用、修改、散布,要標示出處、保留模型名稱(和 CT-Transformer 相同) |
| transcribe.cpp | MIT | |

### 對照事先的假設

1. 速度:**成立,而且比預期好**。短句 TEA-1.1 0.21 秒、mini 0.13 秒(預期 0.8、0.5 秒內),中、長句也快 2–3 倍。
2. SenseVoice:**成立**。最快(短句 0.05 秒),但 Sonnet 評最差,英文常拼錯或漏掉。
3. 準確度:**成立**。使用者盲測 TEA-1.1 對 Breeze 7:2、Qwen-1.7B 對 Breeze 6:1;Sonnet 初篩 TEA-1.1 ≈ Qwen-1.7B > TEA-mini > Breeze。原版 Qwen 英文較常變中文、轉繁體有用詞問題,也和預期相同。
4. 標點:**一半成立**。原版 Qwen3-ASR 有標點,而且使用者 8 題都覺得比 CT 好(比預期好);TEA 微調後幾乎沒有標點(和預期相反)。
5. 放進 App:**成立,但多兩件沒預期到的事**:256 token 上限要切段;1.7B 的記憶體比 Breeze 多約 1GB。

### 使用者盲測(2026-10-22)

私人 repo 的 `U-blind-test.html`(錄音嵌在頁面裡)、答案 `U-key.json`、揭曉後的逐題結果 `U-result.json`。

**辨識**:12 段(短 4、中 5、長 3),從 Breeze、TEA-ASR-1.1、Qwen3-ASR-1.7B 三個結果都不同、而且 Sonnet 判斷差最多的段落挑出來。使用者聽錄音,選最接近講的內容(可複選);三個版本每題隨機排成 A、B、C,標點已拿掉。

| 被選為最接近 | 短(4) | 中(5) | 長(3) | 合計(12) |
|---|---|---|---|---|
| Breeze | 0 | 2 | 1 | 3 |
| TEA-ASR-1.1 | 3 | 3 | 2 | 8 |
| Qwen3-ASR-1.7B | 3 | 5 | 0 | 8 |

| 兩兩比較 | 較好 | 較差 | 一樣 |
|---|---|---|---|
| TEA-ASR-1.1 對 Breeze | 7 | 2 | 3 |
| Qwen3-ASR-1.7B 對 Breeze | 6 | 1 | 5 |
| TEA-ASR-1.1 對 Qwen3-ASR-1.7B | 3 | 3 | 6 |

- 題目是挑「三個都不同」的段落,所以這是「結果不一樣時誰比較對」,不是整體錯誤率(91 段裡 29 段 TEA 和 Breeze 完全相同)。
- Sonnet 對同樣 12 題(三個裡判斷最好的)和使用者完全一致 6 題、部分重疊 5 題、不同 1 題,比上次標點的一致程度好。

**標點**:8 段(短 2、中 4、長 2),同一份 Qwen3-ASR-1.7B 的文字,「它自己的標點」對「去掉後用 CT 補」,從 Sonnet 有偏好的段落挑。**使用者 8 題都選 Qwen 自己的標點**(Sonnet 同樣 8 題有 7 題一致)。注意:隨機排列剛好有 7 題 Qwen 排在 A,使用者那 7 題都選 A,第 8 題 Qwen 排在 B 也選了 B;不能完全排除位置的影響,要更確定可以再加幾題 Qwen 排在 B 的。

### 判斷標準

| | TEA-ASR-1.1 | TEA-ASR-1.1-mini | Qwen3-ASR-1.7B |
|---|---|---|---|
| 短句快 0.4 秒以上 | 符合(1.20 → 0.21 秒) | 符合(→ 0.13 秒) | 符合(→ 0.23 秒) |
| 長句不慢超過 20% | 符合(快 54%) | 符合(快 70%) | 符合(快 47%) |
| 使用者盲測不比 Breeze 差 | 符合(7:2) | 沒測(Sonnet 評在 TEA-1.1 和 Breeze 之間) | 符合(6:1) |
| 英文詞不比 Breeze 差 | 大致符合(照原樣 16 vs 16,變中文 4 vs 2) | 大致符合(14 vs 16,3 vs 2) | 不符合(15 vs 16,變中文 7 vs 2) |
| 繁體 | 符合(原生;簡體字每 1000 字 0.9 個) | 差一點(原生;簡體字每 1000 字 1.7 個) | 不符合(s2twp 每 1000 字約 1.9 個) |
| 記憶體不超過 Breeze(2.73GB) | 不符合(3.69GB) | 符合(1.60GB) | 不符合(3.69GB) |

標點:使用者盲測 Qwen 自己的標點 8:0 勝 CT,符合「讓它取代 CT」的條件(App 遇到有句號的結果本來就會跳過 CT)。TEA 沒有標點,一定要接 CT。

沒有一個候選全部符合:TEA-ASR-1.1 只差記憶體;TEA-mini 沒進使用者盲測、簡體字稍多;Qwen3-ASR-1.7B 英文、繁體、記憶體三項不符合。

## 建議(2026-10-22)

**換掉 Breeze 值得做:辨識快 2–6 倍(短句約 6 倍),使用者盲測也比較準。** 換成哪一個要使用者決定:

1. **首選 TEA-ASR-1.1 + CT 補標點。** 使用者盲測 7:2 勝 Breeze,Sonnet 也評最好;原生繁體、台灣用詞,英文和 Breeze 一樣能保留;短句 1.20 → 0.21 秒、長句中位 4.8 → 2.2 秒。唯一沒過的是記憶體:3.7GB,比 Breeze 多約 1GB(這台 32GB 實際上應該還好,但這是事先訂的標準,要不要放寬由使用者決定)。新版 transcribe.cpp 改用 mmap 後可能變少,沒量。
2. **要省記憶體就用 TEA-ASR-1.1-mini**(1.6GB、短句 0.13 秒)。它沒進使用者盲測,Sonnet 評比 TEA-1.1 稍差,簡體字也多一點;要選它,建議先做一輪 TEA-1.1 對 mini 的盲測。
3. **Qwen3-ASR-1.7B 是「最在意標點」時的選項。** 辨識和 TEA 打平(3:3),自己的標點使用者 8 題都比 CT 好,不用接 CT;但英文較常變中文、要簡轉繁(s2twp 會把「文件」改成「檔案」等)、記憶體和 TEA-1.1 一樣。
4. 不建議 SenseVoice(最快,但錯最多、英文最差)、Qwen3-ASR-0.6B、Fun-ASR-Nano(沒有比 TEA 好的地方)。
5. **換的話要做的事**(這次沒做,另開計畫):
   - transcribe.cpp 的模型清單加 TEA(VoiceInk 已有這條路徑):自己轉的 GGUF 要找地方放(例如自己的 Hugging Face repo),固定版本、記 SHA256。
   - 每 30 秒切段,或把 transcribe.cpp 更新到 2026-09 之後(否則超過約 256 個 token 的長聽寫會整段失敗)。
   - 輸出刪掉私用區字元(U+E000–U+F8FF),或轉檔時就從 token 裡拿掉。
   - 補標點的規則:TEA 偶爾自己加零星標點,要改成先去掉再一律用 CT 補(現在「已有句號就不補」會讓這些段落只剩一兩個標點)。
   - TEA 漏出的簡體字可以用「只轉簡體專用字」的對照表修;不能整段 s2tw(會把「台」轉成「臺」)。
   - Breeze 留著當備用。
6. **CT 的計畫照常進行**:Breeze 和 TEA 都需要它。不過使用者 8 題都偏好 Qwen 自己的標點勝過 CT,表示 CT 的標點還有進步空間。

## 追加:TEA-ASR-1.1 對 TEA-mini 盲測(2026-10-22)

看完上面的結果後,使用者要先比較 TEA-1.1 和 TEA-mini(mini 記憶體 1.6GB、短句 0.13 秒,但沒進第一次的盲測)。

- **做法**:用已經跑好的結果(不重跑模型)。91 段裡兩個模型去標點後有 53 段不同,挑 10 段(短 3、中 5、長 2,不超過 46 秒,不用第一次盲測聽過的段落)。優先挑 Sonnet 判斷有高下的段落,而且兩個方向各半(TEA-1.1 較好、mini 較好),免得題目偏向某一邊;不夠再補 Sonnet 判斷一樣的段落。
- 使用者聽錄音,選 A、B 哪個比較接近講的內容,或「差不多」;A、B 每題隨機。
- **判斷**:mini 不比 TEA-1.1 差(mini 較好的題數 ≥ TEA-1.1 較好的題數 − 1)就建議用 mini(記憶體少 2GB、更快);否則維持建議 TEA-1.1。
