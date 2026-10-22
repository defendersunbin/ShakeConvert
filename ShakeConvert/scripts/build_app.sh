#!/usr/bin/env bash
# ShakeConvert.app 을 "유니버설 바이너리"(Apple Silicon arm64 + Intel x86_64)로 만든다.
# macOS 14+, Xcode 또는 Command Line Tools 필요.
#
# 환경변수 (선택)
#   SIGN_ID  Developer ID Application 인증서 이름. 없으면 ad-hoc 서명(개인 사용용)
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/audit.sh
python3 scripts/check_l10n.py   # 번역 누락·형식 지정자 불일치 시 빌드 중단

APP="build/ShakeConvert.app"
IDENTITY="${SIGN_ID:--}"

# 최소 지원 macOS (Package.swift·Info.plist와 같아야 함)
MIN_MACOS="14.0"
export MACOSX_DEPLOYMENT_TARGET="$MIN_MACOS"

# 아키텍처별로 따로 빌드한 뒤 lipo로 합친다.
# --arch 대신 대상 OS까지 적은 --triple을 써서, 빌드 시스템이 지금 Mac의 OS 버전을
# 대상으로 잡지 않게 한다 (그러면 x86_64 사용 중단·호환 라이브러리 누락 경고가 난다).
BINS=()
for ARCH in arm64 x86_64; do
  TRIPLE="$ARCH-apple-macosx$MIN_MACOS"
  echo "▶ 빌드: $TRIPLE"
  swift build -c release --triple "$TRIPLE" --scratch-path ".build-$ARCH"
  BIN_DIR="$(swift build -c release --triple "$TRIPLE" --scratch-path ".build-$ARCH" --show-bin-path)"
  BINS+=("$BIN_DIR/ShakeConvert")
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "${BINS[@]}" -output "$APP/Contents/MacOS/ShakeConvert"

ARCHS="$(lipo -archs "$APP/Contents/MacOS/ShakeConvert")"
case "$ARCHS" in
  *arm64*x86_64*|*x86_64*arm64*) echo "✅ 유니버설 바이너리 확인: $ARCHS" ;;
  *) echo "❌ 유니버설 바이너리가 아닙니다: $ARCHS" >&2; exit 1 ;;
esac

cp "Resources/Info.plist" "$APP/Contents/Info.plist"
iconutil -c icns Resources/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

# 번역 (macOS가 사용자 언어에 맞는 .lproj를 자동 선택)
for L in Resources/Localization/*.lproj; do
  ditto "$L" "$APP/Contents/Resources/$(basename "$L")"
  plutil -lint -s "$APP/Contents/Resources/$(basename "$L")/Localizable.strings"
done

SIGN_ARGS=(--force --options runtime --entitlements Resources/ShakeConvert.entitlements --sign "$IDENTITY")
if [ "$IDENTITY" != "-" ]; then SIGN_ARGS+=(--timestamp); fi
codesign "${SIGN_ARGS[@]}" "$APP" 2> >(grep -v 'replacing existing signature' >&2)
codesign --verify --deep --strict "$APP"

echo "완료: $APP  v$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")  (서명: $([ "$IDENTITY" = "-" ] && echo 'ad-hoc' || echo "$IDENTITY"))"

# 이전 버전이 실행 중이면 `open`이 새 앱을 띄우지 않고 기존 앱만 활성화한다 → 먼저 종료
if pgrep -x ShakeConvert >/dev/null; then
  pkill -x ShakeConvert || true
  echo "실행 중이던 이전 ShakeConvert를 종료했습니다."
fi
echo "실행: open \"$APP\""
