# VoiceInk 繁中版

在 Mac 上用語音輸入**台灣繁體中文**:全部在本機執行、自動補標點、只有一個 App。

這是 [Beingpax/VoiceInk](https://github.com/Beingpax/VoiceInk)(開源的 macOS 聽寫 App,GPLv3)的 fork,我們的修改都在 `zhtw` 分支:

- **語音辨識**:聯發科 [Breeze-ASR-25](https://huggingface.co/MediaTek-Research/Breeze-ASR-25),針對台灣華語和中英夾雜,直接輸出繁體。
- **補標點**:聯發科 [Breeze2-3B](https://huggingface.co/MediaTek-Research/Llama-Breeze2-3B-Instruct),跑在 VoiceInk 內建的「VoiceInk Refine」引擎裡。**只把標點插回原文,一個字都不改**;模型就算吐出簡體或改寫句子,也不會出現在結果裡。
- 模型已載入時,補標點約 0.8 秒(M1 Pro);用完 5 分鐘沒再用就卸載,釋放約 2GB 記憶體。

架構、決策和各種踩過的坑:[docs/architecture/README.md](docs/architecture/README.md)。

## 安裝

需求:Apple Silicon、16GB 以上記憶體、macOS 15 以上、Xcode(App Store 安裝並打開過一次)、Homebrew。

```bash
git clone -b zhtw https://github.com/Jim-Chang/VoiceInk.git ~/Documents/koding_work/VoiceInk
cd ~/Documents/koding_work/VoiceInk
scripts/setup.sh
```

`setup.sh` 會裝好 Metal 工具鏈、cmake,build 並安裝 VoiceInk,下載兩個模型(固定版本、核對 SHA256)。做過的步驟會自動跳過。

接著:

1. **打開 VoiceInk 完成初始設定**:允許麥克風、輔助使用權限;「模型」那一步選 Local 下載 Parakeet 過關(之後可刪);設定快捷鍵(建議右邊 Option + Hybrid)。
2. 執行 `scripts/setup.sh configure` 寫入設定(中文提示詞改繁體、預設模式用 Breeze + 中文 + VoiceInk Refine)。

隨時可以用 `scripts/setup.sh check` 看狀態。

## 更新

```bash
scripts/update.sh          # 合併原作者最新版、build、安裝
git push origin zhtw
```

## 設定

```bash
# 模型閒置多久卸載(秒,預設 300);重開 VoiceInk 生效
defaults write com.prakashjoshipax.VoiceInk ZhTWRefineKeepWarmSeconds -int 600
```

## 文件

- [docs/architecture/README.md](docs/architecture/README.md):目標、指導原則、架構、決策紀錄
- [docs/development.md](docs/development.md):分支、合併上游、build、測試
- [docs/investigations/](docs/investigations/):聽寫工具與模型比較、簡體的原因、補標點模型評測、單一 App 的可行性、在 App 裡下載模型、延遲
- [docs/plan/](docs/plan/):v1(VoiceInk + LM Studio)、v2(單一 App)、在 App 裡下載模型與打包、補標點換成 CT-Transformer

## 授權

VoiceInk 和這個 fork 的修改都是 [GPLv3](LICENSE)。Breeze-ASR-25 是 Apache 2.0;Breeze2 是 Llama 3.2 Community License。原作者的說明請見 [Beingpax/VoiceInk](https://github.com/Beingpax/VoiceInk)。
