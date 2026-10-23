"""Generate only a deterministic local test signal; no audio device is opened."""
import argparse
import array
import math
import sys
import wave
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("output", type=Path)
args = parser.parse_args()
rate = 48000
samples = array.array("h")
for index in range(rate * 18):
    second, offset = divmod(index, rate)
    frequency = 440 if second % 2 == 0 else 880
    # Short fades prevent clicks while keeping the two tones easy to distinguish.
    envelope = min(1.0, offset / (rate * 0.02), (rate - offset - 1) / (rate * 0.02))
    samples.append(round(32767 * 0.12 * envelope * math.sin(2 * math.pi * frequency * offset / rate)))
if sys.byteorder != "little":
    samples.byteswap()
args.output.parent.mkdir(parents=True, exist_ok=True)
with wave.open(str(args.output), "wb") as output:
    output.setnchannels(1)
    output.setsampwidth(2)
    output.setframerate(rate)
    output.writeframes(samples.tobytes())
print(args.output)
