#!/usr/bin/env bash
# 보안 정책 검사. 빌드(build_app.sh)와 CI에서 매번 실행되며, 하나라도 어기면 실패한다.
set -euo pipefail
cd "$(dirname "$0")/.."

fail=0
check() { # check "설명" "정규식" [제외할 파일 정규식]
  local desc="$1" pattern="$2" exclude="${3:-^$}"
  local hits
  hits="$(grep -rnE "$pattern" Sources/ | grep -vE "$exclude" | grep -vE '^[^:]+:[0-9]+:\s*//' || true)"
  if [ -n "$hits" ]; then
    echo "❌ $desc"
    echo "$hits" | sed 's/^/    /'
    fail=1
  fi
}

# 1. 네트워크: 어떤 통신 API도 쓰지 않는다 (파일은 이 Mac 밖으로 나가지 않음)
check "네트워크 API 사용 금지" \
  'URLSession|URLRequest|NSURLConnection|CFNetwork|CFStream|import Network|NWConnection|NWListener|URL\(string: *"https?:|\.load\(request|Socket'

# 2. 웹 렌더링: WebKit은 원격 리소스를 불러올 수 있으므로 금지
check "WebKit 사용 금지" 'import WebKit|WKWebView|WebView'

# 3. 외부 프로세스/스크립트 실행 금지 (명령어 주입 차단)
check "외부 프로세스·스크립트 실행 금지" \
  'Process\(\)|NSTask|posix_spawn|(^|[^.[:alnum:]_])system\(|popen\(|execv|dlopen|NSAppleScript|OSAScript|NSUserAppleScriptTask'

# 4. 형식 문자열: String(format:)은 번역 헬퍼 한 곳에서만 (사용자 입력이 형식 문자열이 되지 않도록)
check "String(format:)은 Localization.swift에서만" 'String\(format:' '^Sources/ShakeConvert/Localization\.swift:'

# 5. 사용자 파일 삭제 금지: 영구 삭제(removeItem)는 변환용 임시 폴더 정리에서만
check "removeItem은 Converter.swift 임시 폴더 정리에서만" 'removeItem\(' '^Sources/ShakeConvert/Converter\.swift:'

# 5-1. 결과 저장은 원자적 배타 이름 변경(renamex_np RENAME_EXCL)으로만 — 확인 후 이동(moveItem)은 경쟁 조건
check "moveItem/replaceItem 사용 금지 (Converter.finalize의 원자적 저장 사용)" '(^|[^[:alnum:]_])(moveItem|replaceItem|replaceItemAt)\('
check "copyItem은 Converter(무작위 이름 스테이징)와 AppMover(고정 경로 설치)에서만" 'copyItem\(' '^Sources/ShakeConvert/(Converter|AppMover)\.swift:'

# 6. Gatekeeper 격리 속성 제거 금지
check "quarantine 속성 조작 금지" 'com\.apple\.quarantine|removexattr|setxattr'

# 7. 문서 읽기는 반드시 형식을 지정 (형식 추측 → HTML 로더(WebKit)로 빠지는 것 방지)
hits="$(grep -rn 'NSAttributedString(url:' Sources/ | grep -v 'documentType' || true)"
if [ -n "$hits" ]; then echo "❌ NSAttributedString(url:)에는 documentType 지정 필수"; echo "$hits" | sed 's/^/    /'; fail=1; fi
hits="$(grep -rnE 'documentType: *(\.html|NSAttributedString\.DocumentType\.html)' Sources/ || true)"
if [ -n "$hits" ]; then echo "❌ HTML을 입력으로 읽지 않기"; echo "$hits" | sed 's/^/    /'; fail=1; fi

# 8. 권한: entitlements에 예외 키가 없어야 함 (JIT, 라이브러리 검증 해제 등)
if grep -q '<key>' Resources/ShakeConvert.entitlements; then
  echo "❌ entitlements에 권한 키가 있습니다 — 필요한지 검토하세요"; fail=1
fi

# 9. Info.plist: ATS 예외(평문 HTTP 허용 등) 금지
if grep -q 'NSAppTransportSecurity' Resources/Info.plist; then
  echo "❌ Info.plist에 NSAppTransportSecurity 예외가 있습니다"; fail=1
fi

if [ "$fail" -ne 0 ]; then exit 1; fi
echo "✅ 보안 정책 검사 통과 (네트워크·WebKit·프로세스 실행·형식 문자열·파일 삭제·원자적 저장·격리 속성·문서 로더·권한)"
