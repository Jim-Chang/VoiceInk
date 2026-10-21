# 為什麼 Breeze-ASR-25 會輸出簡體:VoiceInk 的中文提示詞

2026-10-21。背景:VoiceInk 已經設定用 Breeze-ASR-25、語言中文,但辨識結果還是簡體(例如「测试一下」)。Breeze-ASR-25 的模型卡說它輸出繁體。

## 原因

- VoiceInk 送給 Whisper 系列模型一段「提示詞」(`initial_prompt`)。內建的中文提示詞是**簡體**:「你好，最近好吗？见到你很高兴。」(`WhisperPrompt.swift` 的 `languagePrompts["zh"]`)。
- Whisper 把提示詞當成「前一段的辨識結果」,會照著前文的字體和風格往下寫,所以 Breeze 被帶成簡體。

## 提示詞是什麼

- Whisper 一次只聽 30 秒,長錄音要切段。訓練時會把上一段的文字一起餵進去,讓前後段的寫法一致;模型因此學會「照前文的風格往下寫」。提示詞就是假的「上一段」。
- 普通話寫成簡體或繁體,聲音完全一樣;Whisper 的語言代碼只有一個 `zh`,訓練資料兩種都有。光聽聲音分不出要哪一種,前文就是最強的線索——強到能蓋過 Breeze 的繁體訓練。
- 它**不是指令**。寫「請輸出繁體字」不會被當成命令;有用的是這句話本身用了繁體字。
- 其他用途:提示詞裡有「,?。」,模型比較會加標點(但 Breeze-ASR-25 還是很少加,所以另外做補標點);放常用的專有名詞,拼對的機率會提高。
- 保持一兩句。太長會被截掉,也可能讓模型在沒講話時吐出提示詞裡的字。只有 Whisper 系列吃提示詞,Parakeet、SenseVoice 不吃。

## 解法

把中文提示詞換成繁體句子,可以順便放常用詞:

```
你好，最近好嗎？今天用 Claude Code 測試語音輸入和標點符號，順便看一下 VoiceInk 的設定。
```

位置:AI Models → Model Settings → Whisper Prompt → Language 選 Chinese → Edit。存在 UserDefaults 的 `CustomLanguagePrompts["zh"]`;`scripts/setup.sh configure` 會在它還是簡體預設值時自動換掉。
