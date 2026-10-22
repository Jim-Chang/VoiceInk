# VoiceInk 繁中版

在 Mac 上用語音輸入**台灣繁體中文**:全部在本機執行、自動補標點、只有一個 App。

這是 [Beingpax/VoiceInk](https://github.com/Beingpax/VoiceInk)(開源的 macOS 聽寫 App,GPLv3)的 fork,我們的修改都在 `zhtw` 分支:

- **語音辨識**:[TEA-ASR-1.1](https://huggingface.co/JacobLinCool/TEA-ASR-1.1)(以 Qwen3-ASR-1.7B 微調的台灣華語模型),原生繁體、台灣用詞、中英夾雜。用 VoiceInk 內建的 transcribe.cpp 執行,短句辨識約 0.2 秒(M1 Pro)。
- **補標點**:[CT-Transformer](https://modelscope.cn/models/iic/punc_ct-transformer_zh-cn-common-vocab272727-pytorch)(FunASR 的中英文標點模型,int8 版跟著 App 一起裝),用 sherpa-onnx 在 App 裡以 CPU 執行,每段幾毫秒。**只把標點插回原文,一個字都不改。**
- 兩個模型都是開始錄音時載入、聽寫結束就釋放,App 閒著時不佔記憶體。

架構、決策和各種踩過的坑:[docs/architecture/README.md](docs/architecture/README.md)。

## 安裝

需求:Apple Silicon、macOS 15 以上、Xcode(App Store 安裝並打開過一次)、Homebrew。記憶體建議 16GB 以上(聽寫時約用 3.7GB,只在 32GB 測過)。

```bash
git clone -b zhtw https://github.com/Jim-Chang/VoiceInk.git ~/Documents/koding_work/VoiceInk
cd ~/Documents/koding_work/VoiceInk
scripts/setup.sh
```

`setup.sh` 會裝好 Metal 工具鏈、cmake,準備 sherpa-onnx 和補標點模型,build 並安裝 VoiceInk,下載語音辨識模型(全部固定版本、核對 SHA256)。做過的步驟會自動跳過。加 `--with-breeze` 會另外下載備用的語音辨識模型,聯發科的 [Breeze-ASR-25](https://huggingface.co/MediaTek-Research/Breeze-ASR-25)(選用)。

接著:

1. **打開 VoiceInk 完成初始設定**:允許麥克風、輔助使用權限;「模型」那一步選 Local,TEA-ASR 1.1 已經由 `setup.sh` 下載好,直接繼續(沒有的話按下載);「AI 服務」那一步可以略過;設定快捷鍵(建議右邊 Option + Hybrid)。
2. 執行 `scripts/setup.sh configure` 寫入設定:預設模式改名「繁中聽寫(TEA-ASR 1.1)」、用 TEA-ASR + 中文,AI 潤稿、文字格式化、自動學習關掉,聽寫紀錄和錄音保留 3 天。

隨時可以用 `scripts/setup.sh check` 看狀態。

**另一台 Mac 不想裝 Xcode、不想編譯**:把已經裝好的 `/Applications/VoiceInk.app` 複製過去就能用(兩台都要是 Apple Silicon、macOS 15 以上;App 裡已經包含補標點模型和函式庫)。打開後照上面的初始設定走,語音辨識模型在「模型」那一步一鍵下載。用 `scp`、`rsync` 等指令複製不會被 macOS 擋;用 AirDrop 或從網路下載的話 macOS 會擋,要到「系統設定 → 隱私權與安全性」允許打開(這種方式還沒實際測過)。設定用下面的匯出、匯入帶過去。

**從另一台已經設定好的 Mac 帶設定過來**:舊的那台在 VoiceInk「設定」最下面按 Export Settings,新的這台按 Import Settings。會帶模式、快捷鍵、Word Replacements、詞彙表;不含 API key 和模型。中文提示詞已經內建在 App 裡,不用另外設定。

## 更新

```bash
scripts/update.sh          # 合併原作者最新版、build、安裝
git push origin zhtw
```

## 設定

```bash
# 暫時關掉補標點(查問題用);刪掉這個設定就恢復
defaults write com.prakashjoshipax.VoiceInk ZhTWPunctuationEnabled -bool false
```

## 文件

- [docs/architecture/README.md](docs/architecture/README.md):目標、指導原則、架構、決策紀錄
- [docs/development.md](docs/development.md):分支、合併上游、build、測試
- [docs/investigations/](docs/investigations/):聽寫工具與模型比較、簡體的原因、補標點模型評測、單一 App 的可行性、在 App 裡下載模型、延遲、換語音辨識模型
- [docs/plan/](docs/plan/):v1(VoiceInk + LM Studio)、v2(單一 App)、在 App 裡下載模型與打包、補標點換成 CT-Transformer、語音辨識換成 TEA-ASR

## 授權

VoiceInk 和這個 fork 的修改都是 [GPLv3](LICENSE)。原作者的說明請見 [Beingpax/VoiceInk](https://github.com/Beingpax/VoiceInk)。

用到的模型和函式庫:

| | 授權 | 來源 |
|---|---|---|
| TEA-ASR-1.1 | MIT(底層 Qwen3-ASR-1.7B 是 Apache 2.0) | [JacobLinCool/TEA-ASR-1.1](https://huggingface.co/JacobLinCool/TEA-ASR-1.1),轉成 transcribe.cpp 格式放在 [dorajim15/TEA-ASR-1.1-transcribe-cpp](https://huggingface.co/dorajim15/TEA-ASR-1.1-transcribe-cpp) |
| CT-Transformer 標點模型 | Apache 2.0(ModelScope 頁面);FunASR 模型授權要求註明來源、保留模型名稱 | 阿里巴巴 FunASR 的 [punc_ct-transformer_zh-cn-common-vocab272727-pytorch](https://modelscope.cn/models/iic/punc_ct-transformer_zh-cn-common-vocab272727-pytorch),sherpa-onnx 轉成的 `sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12-int8` |
| sherpa-onnx | Apache 2.0 | [k2-fsa/sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) |
| ONNX Runtime | MIT | [microsoft/onnxruntime](https://github.com/microsoft/onnxruntime) |
| Breeze-ASR-25(選用的備用) | Apache 2.0 | [MediaTek-Research/Breeze-ASR-25](https://huggingface.co/MediaTek-Research/Breeze-ASR-25) |
