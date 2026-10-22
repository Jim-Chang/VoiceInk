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
