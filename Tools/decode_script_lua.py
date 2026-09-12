#!/usr/bin/env python3
import ast
import re
import urllib.request

URL = "https://raw.githubusercontent.com/yumyum272/driving/refs/heads/main/script.lua"


def safe_eval(expr: str) -> int:
    expr = expr.strip()
    if not re.fullmatch(r"[0-9+\-() ]+", expr):
        raise ValueError(f"unsafe arithmetic: {expr!r}")
    return int(eval(expr, {"__builtins__": {}}, {}))


def lua_decimal_unescape(s: str) -> str:
    return re.sub(r"\\(\d{1,3})", lambda m: chr(int(m.group(1))), s)


def decode_custom(encoded: str, mapping: dict[str, int]) -> bytes:
    out = bytearray()
    acc = 0
    count = 0
    i = 0
    while i < len(encoded):
        ch = encoded[i]
        if ch in mapping:
            acc += mapping[ch] * (64 ** (3 - count))
            count += 1
            if count == 4:
                out.extend((acc // 65536, (acc % 65536) // 256, acc % 256))
                acc = 0
                count = 0
        elif ch == "=":
            out.append(acc // 65536)
            if i + 1 >= len(encoded) or encoded[i + 1] != "=":
                out.append((acc % 65536) // 256)
            break
        i += 1
    return bytes(out)


def printable_ratio(b: bytes) -> float:
    if not b:
        return 1.0
    return sum((32 <= x <= 126) or x in (9, 10, 13) for x in b) / len(b)


src = urllib.request.urlopen(URL, timeout=20).read().decode("utf-8")
print(f"SOURCE_BYTES={len(src.encode())}")

m = re.search(r"local g=\{(.*?)\}for E,I in ipairs", src, re.S)
if not m:
    raise SystemExit("initial string table not found")
body = m.group(1)
raw_tokens = re.findall(r'"((?:\\.|[^"\\])*)"', body)
arr = [lua_decimal_unescape(x) for x in raw_tokens]
print(f"RAW_STRINGS={len(arr)}")

# Exact permutation encoded in this blob:
# {{1,263},{1,134},{135,263}}
for lo, hi in ((1, 263), (1, 134), (135, 263)):
    arr[lo-1:hi] = reversed(arr[lo-1:hi])

hm = re.search(r"local H=\{(.*?)\}local G=table\.insert", src, re.S)
if not hm:
    raise SystemExit("custom alphabet not found")
hbody = hm.group(1)
parts = re.split(r"[;,]", hbody)
mapping = {}
for part in parts:
    if "=" not in part:
        continue
    k, expr = part.split("=", 1)
    k = k.strip()
    expr = expr.strip()
    if k.startswith('["') and k.endswith('"]'):
        key = lua_decimal_unescape(k[2:-2])
    elif re.fullmatch(r"[A-Za-z]", k):
        key = k
    else:
        continue
    try:
        mapping[key] = safe_eval(expr)
    except Exception:
        pass

print(f"ALPHABET={len(mapping)} values={len(set(mapping.values()))}")
if len(mapping) != 64 or set(mapping.values()) != set(range(64)):
    raise SystemExit("alphabet parse failed")

decoded = [decode_custom(x, mapping) for x in arr]

with open("script_lua_decoded_strings.txt", "w", encoding="utf-8") as f:
    for idx, b in enumerate(decoded, 1):
        if printable_ratio(b) >= 0.85:
            text = b.decode("utf-8", "backslashreplace")
            f.write(f"[{idx:03d}] {text!r}\n")
        else:
            f.write(f"[{idx:03d}] HEX:{b.hex()}\n")

print("=== PRINTABLE CONSTANTS ===")
for idx, b in enumerate(decoded, 1):
    if printable_ratio(b) >= 0.95:
        text = b.decode("utf-8", "replace")
        print(f"[{idx:03d}] {text!r}")

print("=== KEY-LIKE CANDIDATES ===")
for idx, b in enumerate(decoded, 1):
    if printable_ratio(b) < 1.0:
        continue
    s = b.decode("latin1")
    if 4 <= len(s) <= 80 and (
        re.search(r"[A-Z]", s) and re.search(r"[0-9]", s)
        or "key" in s.lower()
        or "access" in s.lower()
        or "unlock" in s.lower()
    ):
        print(f"CANDIDATE [{idx:03d}] {s!r}")

# Also report constants referenced near the visible gate-related API names once
# the first layer is available. This is purely static; nothing is executed.
print("OUTPUT_FILE=script_lua_decoded_strings.txt")
