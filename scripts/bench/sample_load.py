#!/usr/bin/env python3
"""每 0.5 秒記一次 GPU 使用率和最吃 CPU 的程序,給 scripts/timing_report.py --load 對照用。

用法: python3 -I scripts/bench/sample_load.py 輸出檔.tsv [秒數,預設 900]

- GPU:ioreg 的 "Device Utilization %"(整台 GPU,包含 VoiceInk 自己)。
- CPU:用兩次取樣之間各程序累積 CPU 時間的差算出瞬間使用率(ps 的 %cpu 是一分鐘的平均,不夠即時)。
"""
import re
import subprocess
import sys
import time
from datetime import datetime

INTERVAL = 0.5
GPU_PATTERN = re.compile(r'"Device Utilization %"=(\d+)')


def gpu_utilization():
    out = subprocess.run(
        ["ioreg", "-r", "-d", "1", "-w", "0", "-c", "IOAccelerator"],
        capture_output=True, text=True,
    ).stdout
    match = GPU_PATTERN.search(out)
    return int(match.group(1)) if match else -1


def cpu_times():
    """pid -> (累積 CPU 秒數, 程式名稱)"""
    out = subprocess.run(
        ["ps", "-Ao", "pid=,cputime=,comm="], capture_output=True, text=True
    ).stdout
    result = {}
    for line in out.splitlines():
        parts = line.split(None, 2)
        if len(parts) < 3:
            continue
        pid, cputime, command = parts
        seconds = 0.0
        for field in cputime.split(":"):
            seconds = seconds * 60 + float(field)
        result[pid] = (seconds, command.rsplit("/", 1)[-1])
    return result


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    output = sys.argv[1]
    duration = float(sys.argv[2]) if len(sys.argv) > 2 else 900
    deadline = time.monotonic() + duration
    previous = cpu_times()
    previous_at = time.monotonic()
    with open(output, "w", encoding="utf-8") as f:
        f.write("time\tgpu\ttop_cpu\n")
        while time.monotonic() < deadline:
            time.sleep(INTERVAL)
            gpu = gpu_utilization()
            current = cpu_times()
            now = time.monotonic()
            elapsed = now - previous_at
            usage = []
            for pid, (seconds, name) in current.items():
                if pid in previous:
                    percent = (seconds - previous[pid][0]) / elapsed * 100
                    if percent >= 5:
                        usage.append((percent, name))
            usage.sort(reverse=True)
            top = ", ".join(f"{name}:{percent:.0f}" for percent, name in usage[:4])
            stamp = datetime.now().strftime("%H:%M:%S.%f")[:-3]
            f.write(f"{stamp}\t{gpu}\t{top}\n")
            f.flush()
            previous, previous_at = current, now


if __name__ == "__main__":
    main()
