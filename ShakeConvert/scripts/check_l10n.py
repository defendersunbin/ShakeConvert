#!/usr/bin/env python3
"""번역 검증 (빌드 시 자동 실행, 실패하면 빌드 중단)

1. 소스의 모든 L("…") 키가 모든 언어 파일에 있는지
2. 번역문의 형식 지정자(%@, %ld 등)가 원문과 종류·순서가 같은지
   → 다르면 String(format:)이 잘못된 인자를 읽어 앱이 죽거나 메모리를 잘못 읽을 수 있음 (형식 문자열 취약점)
3. 번역문에 원문에 없는 형식 지정자가 끼어들지 않았는지
"""
import glob
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SPEC = re.compile(r"%(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?(?:hh|h|ll|l|q|z|t|j)?[@dDiuUxXoOfeEgGcCsSpaAF%]")
KEY = re.compile(r'\bL\("((?:[^"\\]|\\.)*)"')
ENTRY = re.compile(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";\s*$')


def unescape(s):
    return s.replace('\\"', '"').replace("\\n", "\n").replace("\\\\", "\\")


def specs(s):
    return [m for m in SPEC.findall(s) if m != "%%"]


def main():
    keys = set()
    for f in glob.glob(os.path.join(ROOT, "Sources", "**", "*.swift"), recursive=True):
        with open(f, encoding="utf-8") as fh:
            keys.update(unescape(k) for k in KEY.findall(fh.read()))

    problems = []
    lproj_dirs = sorted(glob.glob(os.path.join(ROOT, "Resources", "Localization", "*.lproj")))
    if not lproj_dirs:
        problems.append("번역 폴더가 없습니다 (python3 scripts/translations.py Resources/Localization)")

    for d in lproj_dirs:
        lang = os.path.basename(d)
        table = {}
        with open(os.path.join(d, "Localizable.strings"), encoding="utf-8") as fh:
            for n, line in enumerate(fh, 1):
                line = line.strip()
                if not line or line.startswith("/*"):
                    continue
                m = ENTRY.match(line)
                if not m:
                    problems.append(f"{lang}:{n}: 형식 오류: {line[:60]}")
                    continue
                table[unescape(m.group(1))] = unescape(m.group(2))

        for k in sorted(keys - table.keys()):
            problems.append(f"{lang}: 번역 누락: {k}")
        for k, v in table.items():
            if specs(k) != specs(v):
                problems.append(f"{lang}: 형식 지정자 불일치: {k!r} {specs(k)} ≠ {v!r} {specs(v)}")

    if problems:
        print("❌ 번역 검사 실패")
        for p in problems:
            print("  -", p)
        sys.exit(1)
    print(f"✅ 번역 검사 통과: {len(keys)}개 문자열 × {len(lproj_dirs)}개 언어")


if __name__ == "__main__":
    main()
