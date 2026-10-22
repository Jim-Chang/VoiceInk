#!/usr/bin/env python3
"""用官方 qwen-asr 套件(PyTorch)跑 TEA-ASR,當作自己轉的 GGUF 的對照答案。

只用來檢查轉檔有沒有出錯,不量速度。和 GGUF 版一樣指定中文(language="Chinese")、greedy。

用法(transcribe.cpp 的 scripts/envs/qwen3_asr 環境):
  python -I tea_reference.py --model <TEA 資料夾> --list subset.tsv --output ref.json [--device cpu|mps]
subset.tsv 每行「id<TAB>wav 路徑」。
"""
import argparse
import json
import time

import torch
from qwen_asr import Qwen3ASRModel


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True)
    parser.add_argument("--list", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--device", default="cpu")
    args = parser.parse_args()

    rows = [line.rstrip("\n").split("\t") for line in open(args.list, encoding="utf-8") if "\t" in line]
    model = Qwen3ASRModel.from_pretrained(args.model, dtype=torch.float32, device_map=args.device,
                                          max_new_tokens=1024)
    out = {"model": args.model, "device": args.device, "rows": {}}
    for item_id, wav in rows:
        started = time.monotonic()
        result = model.transcribe(audio=wav, language="Chinese")[0]
        out["rows"][item_id] = {"text": result.text, "language": result.language,
                                "seconds": time.monotonic() - started}
        print(item_id, f"{out['rows'][item_id]['seconds']:.1f}s", flush=True)
        json.dump(out, open(args.output, "w", encoding="utf-8"), ensure_ascii=False, indent=1)


if __name__ == "__main__":
    main()
