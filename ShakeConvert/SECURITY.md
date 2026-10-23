# 보안 정책 / Security Policy

ShakeConvert는 **파일을 절대 이 Mac 밖으로 보내지 않는 것**을 가장 중요한 원칙으로 합니다.
ShakeConvert never sends your files anywhere. Every conversion runs locally with macOS system frameworks.

## 설계 원칙

| 위협 | 대응 |
|---|---|
| 파일 유출 | 네트워크 API(URLSession, Network 등)를 전혀 사용하지 않음. `scripts/audit.sh`가 빌드·CI마다 검사 |
| 원격 리소스 로딩 | WebKit 미사용. HTML은 **입력으로 읽지 않음**(출력만). 문서 로더는 항상 형식(RTF/DOCX)을 명시해 HTML 로더로 빠지지 않음 |
| 명령어 주입 | 외부 프로세스·쉘·AppleScript를 앱에서 실행하지 않음. 파일 이름은 어떤 명령에도 들어가지 않음 |
| 형식 문자열 취약점 | `String(format:)`은 번역 헬퍼 한 곳에서만 사용. 번역문의 형식 지정자(%@, %ld)가 원문과 다르면 빌드 실패 (`scripts/check_l10n.py`) |
| 생성 문서의 스크립트 삽입 | 마크다운 → HTML 변환 시 모든 텍스트를 이스케이프하고, 링크는 `http`/`https`/`mailto`만 허용, `Content-Security-Policy: default-src 'none'` 포함 |
| 입력 문서에 숨은 위험 링크 | RTF/DOCX를 변환할 때 `javascript:`·`file:` 등 위험한 링크를 제거. HTML로 내보낼 때는 첨부(로컬 파일 경로가 될 수 있음)를 빼고 CSP를 넣음 |
| 자원 고갈(압축 폭탄 등) | 파일 크기·글자 수에는 상한이 없음. 대신 큰 텍스트·마크다운은 1MB씩 조각 내어 변환·저장하므로 메모리가 파일 크기에 비례해 늘지 않고, 영상·오디오·PDF는 조금씩 읽어 처리. 큰 Word/RTF도 문단 단위로 읽고(DOCX는 zip을 직접 열어 조금씩 풀며 CRC·크기 검증, 외부 엔티티 미해석), DOCX 출력은 ZIP64로 4GB 초과 지원. 모든 출력은 디스크 여유 128MB 미만이면 깔끔히 중단. 이미지는 고정 상한 대신 이 Mac 메모리 기준 예산(곱셈 오버플로 검사 포함). 표 열 20개, 한 번에 100개 파일. 모든 변환은 진행률 표시와 취소 가능 |
| 원본·기존 파일 훼손 | 원본은 읽기만 함. 결과는 소유자 전용(0700) 임시 폴더에서 만든 뒤 `renamex_np(RENAME_EXCL)`로 **원자적으로** 배치 — 대상이 이미 있으면(심볼릭 링크 포함) 커널이 거부하므로 확인과 저장 사이의 경쟁 조건이 없음. 다른 볼륨이면 대상 폴더에 무작위 이름으로 복사한 뒤 같은 방식으로 배치. 영구 삭제는 임시 파일 정리에만 허용 |
| 암호 PDF의 암호 노출 | 입력한 암호는 해제 시도에만 쓰고 저장·기록하지 않으며 시도 직후 입력값을 비움. 암호 입력 중에는 바깥 클릭·자동 닫기가 작동하지 않아 입력이 도중에 사라지지 않음 |
| 파일 이름 위장 | 결과 파일 이름에서 제어 문자와 양방향(RLO 등) 문자를 제거해 `photo‮gpj.exe` 같은 확장자 위장을 막고 길이를 제한 |
| 심볼릭 링크 조작 | 입력이 심볼릭 링크면 거부. 설치 도우미는 대상이 링크이거나 다른 앱이면 건드리지 않음 |
| 설치 도우미 오용 | 대상 경로 고정(`/Applications/ShakeConvert.app`), 같은 번들 ID일 때만 교체, 기존 버전은 휴지통으로(복구 가능), 복사본이 **실행 중인 앱과 같은 서명 신원**(지정 요구 사항)을 만족할 때만 실행, Gatekeeper 격리 속성 유지 |
| 설정 값 주입 | 모든 설정은 허용된 값(열거형/범위)으로만 해석. 언어 코드도 허용 목록만 저장 |
| 클립보드 노출 | 일반 클립보드는 읽지 않음. 드래그 중인 파일 목록만 드래그 전용 pasteboard에서 읽음 |
| 메타데이터 유출 | 이미지 변환 결과에 EXIF/GPS 등 메타데이터를 복사하지 않음 |
| 런타임 변조 | Hardened Runtime으로 서명. entitlements 예외 없음(검사 스크립트가 강제) |
| CI 공급망 | GitHub Actions 권한 `contents: read`, 외부 액션은 커밋 SHA로 고정, 자격 증명 비보존 |

## 남아 있는 위험 (알고 있는 한계)

- **App Sandbox 미적용**: 이미지·PDF·문서·영상 해석은 Apple 시스템 프레임워크(ImageIO, PDFKit, AVFoundation 등)가 합니다. 이 프레임워크에 알려지지 않은 취약점이 있고 조작된 파일이 그것을 노린다면, 코드는 사용자 권한으로 실행됩니다. 샌드박스는 이런 경우에도 피해를 앱 안에 가두는 최종 방어선이지만, 켜면 "원본 파일 옆에 저장"이 불가능해져(다운로드 폴더 고정 또는 폴더 접근 허용 필요) 현재는 적용하지 않았습니다. macOS를 최신으로 유지하는 것이 이 위험을 줄이는 가장 효과적인 방법입니다.
- 위 검사들은 **이 앱의 코드**를 대상으로 합니다. 시스템 프레임워크 내부 동작(예: DOCX 해석기가 외부 리소스를 참조하는지)은 앱 코드로 강제할 수 없으며, 이것도 샌드박스(네트워크 권한 없음)로만 완전히 막을 수 있습니다.

## 배포본 확인

```bash
shasum -a 256 ShakeConvert-*.dmg                       # 릴리스에 적힌 값과 비교
codesign --verify --deep --strict --verbose=2 /Applications/ShakeConvert.app
spctl --assess --type execute -v /Applications/ShakeConvert.app   # 공증된 배포본이면 accepted
```

## 취약점 신고 / Reporting a vulnerability

공개 이슈 대신 GitHub의 **Security › Report a vulnerability**(비공개 신고)를 이용해 주세요.
Please use GitHub's private vulnerability reporting instead of public issues.
