#!/usr/bin/env bash
# 디자인된 설치용 DMG를 만든다. 결과: dist/ShakeConvert-<버전>.dmg
#  - Apple Silicon / Intel 모두에서 실행되는 유니버설 앱
#  - 배경 이미지 + 아이콘 배치(앱 → Applications로 끌어다 놓기), 볼륨 아이콘
#
# 환경변수 (선택, 다른 사람에게 배포할 때)
#   SIGN_ID         Developer ID Application 인증서 이름 (예: "Developer ID Application: Name (TEAMID)")
#   NOTARY_PROFILE  `xcrun notarytool store-credentials` 로 저장한 프로필 이름 → 공증 + 스테이플
set -euo pipefail
cd "$(dirname "$0")/.."

VOL="ShakeConvert"
APP_POS="170, 214"      # scripts/make_dmg_background.py 의 APP 과 같아야 함
APPS_POS="490, 214"     # 〃 APPS
WIN_W=660; WIN_H=420

./scripts/build_app.sh

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
DMG="dist/ShakeConvert-${VERSION}.dmg"
WORK="$(mktemp -d)"
RW_DMG="$WORK/rw.dmg"
STAGE="$WORK/stage"
DEVICE=""

cleanup() {
  if [ -n "$DEVICE" ]; then hdiutil detach "$DEVICE" -quiet -force >/dev/null 2>&1 || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# 1) 내용물 준비
mkdir -p "$STAGE/.background"
ditto build/ShakeConvert.app "$STAGE/ShakeConvert.app"      # 서명/속성 보존 복사
ln -s /Applications "$STAGE/Applications"
tiffutil -cathidpicheck Resources/dmg/background.png Resources/dmg/background@2x.png \
  -out "$STAGE/.background/background.tiff" >/dev/null
cp build/ShakeConvert.app/Contents/Resources/AppIcon.icns "$STAGE/.VolumeIcon.icns"

# 같은 이름의 디스크(이전에 열어 둔 DMG 등)가 마운트돼 있으면, 새 디스크가 "ShakeConvert 1"로 붙고
# Finder 레이아웃이 엉뚱한 디스크에 적용되어 디자인 없는 DMG가 만들어진다 → 모두 꺼내고, 못 꺼내면 중단
for m in /Volumes/"$VOL" /Volumes/"$VOL "[0-9]*; do
  [ -d "$m" ] || continue
  echo "▶ 열려 있는 디스크 꺼내는 중: $m"
  hdiutil detach "$m" -quiet || hdiutil detach "$m" -quiet -force || true
done
for m in /Volumes/"$VOL" /Volumes/"$VOL "[0-9]*; do
  if [ -d "$m" ]; then
    echo "❌ '$m' 디스크를 꺼낼 수 없습니다. Finder에서 해당 디스크를 꺼낸(⏏) 뒤 다시 실행하세요." >&2
    exit 1
  fi
done

# 2) 쓰기 가능한 DMG 생성 → 마운트
# 방금 복사한 앱을 macOS 보안 검사·Spotlight가 잠깐 붙잡고 있으면 "리소스 사용 중"으로 실패하므로 재시도.
# (-size를 함께 쓰는 형태는 사용 중단 예정이라, 내용물 크기로 만든 뒤 여유 공간을 따로 늘린다)
SIZE_MB=$(( $(du -sm "$STAGE" | cut -f1) + 20 ))
sleep 1
created=0
for attempt in 1 2 3 4 5 6; do
  if hdiutil create -srcfolder "$STAGE" -volname "$VOL" -fs HFS+ -format UDRW -ov "$RW_DMG" \
       >/dev/null 2>"$WORK/hdiutil.log"; then
    created=1
    break
  fi
  echo "  디스크 이미지 생성 재시도 ($attempt/6): $(grep -v 'deprecated' "$WORK/hdiutil.log" | tail -1)"
  sleep $(( attempt * 2 ))
done
if [ "$created" -ne 1 ]; then
  echo "❌ 디스크 이미지를 만들지 못했습니다:" >&2
  cat "$WORK/hdiutil.log" >&2
  exit 1
fi
# Finder가 창 설정을 저장할 여유 공간 확보
hdiutil resize -size "${SIZE_MB}m" "$RW_DMG" >/dev/null 2>&1 || true
ATTACH="$(hdiutil attach -readwrite -noverify -noautoopen "$RW_DMG")"
DEVICE="$(echo "$ATTACH" | awk '/^\/dev\// {print $1; exit}')"
MOUNT="$(echo "$ATTACH" | grep -o '/Volumes/.*$' | head -1 | sed 's/[[:space:]]*$//')"
# 실제로 붙은 위치를 확인 — 다른 이름("ShakeConvert 1" 등)이면 레이아웃이 엉뚱한 곳에 적용되므로 중단
if [ "$MOUNT" != "/Volumes/$VOL" ]; then
  echo "❌ 새 디스크가 '$MOUNT'에 연결됐습니다 (기대: /Volumes/$VOL). 같은 이름의 디스크를 꺼내고 다시 실행하세요." >&2
  exit 1
fi
sleep 1

# 볼륨 아이콘 사용 표시 (SetFile은 Xcode/CLT에 포함. 없으면 건너뜀)
if command -v SetFile >/dev/null; then SetFile -a C "$MOUNT" || true; fi

# 3) Finder 창 레이아웃 (처음 실행 시 "터미널이 Finder를 제어" 허용 창이 뜰 수 있음)
if ! osascript <<EOF
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, $((200 + WIN_W)), $((120 + WIN_H + 28))}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 128
    set text size of viewOptions to 13
    set background picture of viewOptions to file ".background:background.tiff"
    set position of item "ShakeConvert.app" of container window to {$APP_POS}
    set position of item "Applications" of container window to {$APPS_POS}
    close
    open
    -- 다시 연 뒤에도 같은 크기를 한 번 더 지정 (Finder가 기본 크기로 여는 경우 대비)
    set the bounds of container window to {200, 120, $((200 + WIN_W)), $((120 + WIN_H + 28))}
    update without registering applications
    delay 2
    close
  end tell
end tell
EOF
then
  LAYOUT_OK=0
else
  LAYOUT_OK=1
fi

# Finder가 창 설정(.DS_Store)을 디스크에 실제로 쓸 때까지 기다린 뒤 분리 (너무 빨리 분리하면 창 크기가 저장되지 않음)
for _ in $(seq 1 20); do
  [ -f "$MOUNT/.DS_Store" ] && break
  sleep 0.5
done
sleep 1

# 디자인(배경·아이콘 배치)이 실제로 저장됐는지 확인 — 실패하면 디자인 없는 DMG를 만들지 않고 중단
if [ "$LAYOUT_OK" -ne 1 ] || [ ! -f "$MOUNT/.DS_Store" ]; then
  echo "❌ DMG 창 디자인(배경·아이콘 배치)을 적용하지 못했습니다." >&2
  echo "   1) 시스템 설정 › 개인정보 보호 및 보안 › 자동화에서 '터미널 → Finder'를 허용하세요." >&2
  echo "   2) Finder 사이드바에 ShakeConvert 디스크가 있으면 꺼내세요(⏏)." >&2
  echo "   그런 다음 다시 실행하세요." >&2
  exit 1
fi
echo "✅ DMG 창 디자인 적용 확인"

# 4) 정리 후 읽기 전용 압축 DMG로 변환
rm -rf "$MOUNT/.fseventsd" "$MOUNT/.Trashes" 2>/dev/null || true
chmod -Rf go-w "$MOUNT" || true
sync
hdiutil detach "$DEVICE" -quiet
DEVICE=""

mkdir -p dist
rm -f "$DMG"
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null

if [ -n "${SIGN_ID:-}" ]; then
  codesign --force --timestamp --sign "$SIGN_ID" "$DMG"
fi

if [ -n "${NOTARY_PROFILE:-}" ]; then
  if [ -z "${SIGN_ID:-}" ]; then echo "❌ 공증에는 SIGN_ID(Developer ID 서명)가 필요합니다." >&2; exit 1; fi
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi

echo
echo "완료: $DMG"
shasum -a 256 "$DMG"
echo "확인: open \"$DMG\""
