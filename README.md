# ShakeConvert
--------------------------------------------------------------------------------------------------------------------------------------
<p align="center">
<img width="256" height="256" alt="app-icon" src="https://github.com/user-attachments/assets/e5828c63-aa02-4dd0-a3c4-ca5b9edc2a19" />
</p>
파일을 잡은 채 좌우로 흔들면, 잡고 있는 커서를 중심으로 변환 형식이 360°로 펼쳐집니다.
원하는 방향으로 밀어서 놓으면 끝. 모든 변환은 사용자의 Mac 안에서만 이루어집니다.

| 다크 | 라이트 |
|---|---|
| <img width="340" height="418" alt="shakeconvert_dark" src="https://github.com/user-attachments/assets/1e8952e6-2d27-430e-a1e6-b7cf08564c3d" /> | <img width="340" height="418" alt="shakeconvert_light" src="https://github.com/user-attachments/assets/514d8afb-daa9-480f-a3f9-33d376b040ed" /> |

## 특징

- **360° 링 메뉴**: 커서가 링의 중심. 최대 7개 형식이 12시부터 시계 방향, `etc`는 항상 3시 방향
- **방향으로 선택**: 조각 안에 정확히 놓지 않아도 그 방향이면 선택. 가운데에 놓으면 변환 없이 자연스럽게 닫힘
- **진행률 표시**: 변환 중에는 링이 실제 진행률만큼 차오르고 가운데에 % 표시 (여러 파일이면 아래에 2/5처럼 표시). 가운데를 누르거나 Esc로 취소
- **변환 모션**: 완료(링이 차오르고 체크) / 실패(붉은 링과 흔들림)
- **자연스러운 문서 변환**: txt·md → PDF는 머리글·바닥글·쪽 번호·구분선이 있는 문서로, 코드는 상자, 인용은 막대, 표는 테두리로 조판
- **라이트 / 다크 / 시스템** 테마
- **8개 언어**: 한국어, English, 日本語, 简体中文, 繁體中文, Español, Français, Deutsch — 시스템 언어를 자동으로 따르고 설정에서 바꿀 수도 있음
- **Apple Silicon + Intel** 유니버설 앱, 디자인된 설치용 DMG

## 사용법

1. DMG를 열고 ShakeConvert를 Applications로 끌어다 놓기 (DMG에서 바로 실행하면 앱이 사용자 언어로 "응용 프로그램 폴더로 옮길까요?"를 묻고 직접 옮겨 줍니다)
2. 실행하면 상단에 "실행 중" 알림이 뜨고 메뉴바에 `⇄` 아이콘이 생김 (Dock 아이콘 없음)
3. 파일을 잡고 좌우로 3~4번 흔들기
4. 원하는 형식 방향으로 밀어서 놓기 (놓은 뒤 클릭해도 됨)
5. 다른 형식은 맨 위 검색창에 입력하거나 `etc`로 → `Enter`로 첫 결과 변환, `Esc`로 닫기
6. 결과는 원본 옆(또는 설정한 다운로드 폴더)에 새 파일로 저장. 같은 이름이 있으면 `이름 2.jpg`처럼 번호가 붙고 절대 덮어쓰지 않음

## 지원 변환

| 입력 | 출력 |
|---|---|
| 이미지 (HEIC, JPEG, PNG, TIFF, GIF, BMP, JPEG 2000, RAW 등) | JPEG, PNG, HEIC, PDF, SVG\*, TIFF, GIF, BMP, JPEG 2000 |
| 마크다운 (md) | PDF(조판), HTML(스타일·라이트/다크 대응), Word, RTF, 텍스트 |
| 텍스트 (txt) | PDF(조판), HTML, Word, RTF |
| RTF / Word (docx) | PDF(조판), HTML, Word/RTF, 텍스트 |
| PDF | PNG/JPEG (페이지별), 텍스트 (페이지 구분선 포함) |
| 오디오 | M4A, WAV, AIFF, CAF |
| 비디오 | MP4, MOV, M4A(오디오만) |

\* SVG는 벡터 변환(트레이싱)이 아니라 래스터 이미지를 SVG 안에 포함하는 방식입니다.

## 설정 (메뉴바 `⇄` › 설정… / ⌘,)

| 항목 | 선택지 |
|---|---|
| 로그인 시 자동 실행 | 켬 / 끔 |
| 실행할 때 알림 표시 | 켬 / 끔 |
| 테마 | 시스템 / 라이트 / 다크 |
| 표시 언어 | 시스템 언어 따르기 / 8개 언어 (다시 시작 시 적용) |
| 흔들기 감도 | 둔감 / 보통 / 민감 |
| 저장 위치 | 원본 파일 옆 / 다운로드 폴더 |
| 변환 완료 후 자동으로 닫기 | 5초 / 10초 / 15초 / 30초 / 1분 / 닫지 않음 (실패 시에는 오류를 읽을 수 있게 열어 둠) |
| 변환 후 Finder에서 결과 보기 | 켬 / 끔 |
| JPEG · HEIC 품질 | 60 ~ 100% |
| 문서 → PDF 용지 | A4 / Letter |

## 빌드 & 설치용 DMG 만들기

macOS 14 이상, Xcode 또는 Command Line Tools 필요.

```bash
./scripts/build_dmg.sh        # → dist/ShakeConvert-<버전>.dmg (유니버설)
```

![설치 창](docs/images/dmg.png)

- 처음 실행 시 "터미널이 Finder를 제어" 허용 창이 뜰 수 있습니다 (DMG 창 배경·아이콘 배치에 필요). 거부해도 DMG는 만들어지지만 배치가 적용되지 않습니다.
- 앱만 필요하면 `./scripts/build_app.sh` → `build/ShakeConvert.app`
- DMG 창 배경은 Finder가 보여주는 정적 이미지라 언어별로 바꿀 수 없습니다. 그래서 문장 없이 아이콘·화살표·형식 이름만으로 디자인했고, 언어별 안내는 앱이 처음 실행될 때 사용자의 언어로 표시됩니다.

### 서명과 Gatekeeper

| 방식 | 명령 | 다른 Mac에서 열 때 |
|---|---|---|
| ad-hoc (기본, 개인용) | `./scripts/build_dmg.sh` | 처음 열 때 차단됨 → 시스템 설정 › 개인정보 보호 및 보안 › 맨 아래 **"그래도 열기"** → 암호 입력 (macOS 15부터 우클릭 › 열기로는 우회 불가) |
| Developer ID + 공증 (배포용) | `SIGN_ID="Developer ID Application: 이름 (TEAMID)" NOTARY_PROFILE=프로필 ./scripts/build_dmg.sh` | 경고 없이 실행 |

## 보안

자세한 내용은 [SECURITY.md](SECURITY.md). 요약하면:

- 네트워크·WebKit·외부 프로세스 실행 없음, 원본은 읽기만, 덮어쓰기 없음
- `scripts/audit.sh`가 빌드와 CI마다 보안 규칙을 검사하고 어기면 빌드 실패
- `scripts/check_l10n.py`가 번역 누락과 형식 지정자 불일치(형식 문자열 취약점)를 검사
- GitHub Actions(CI)가 푸시마다 보안 검사 → 번역 검사 → 유니버설 빌드 → 서명 확인

## 번역 수정·추가

번역 원본은 `scripts/translations.py` 한 곳입니다. 수정 후:

```bash
python3 scripts/translations.py Resources/Localization
python3 scripts/check_l10n.py
```

## 프로젝트 구조

```
Sources/ShakeConvert/
  App.swift              메뉴바, 시작 처리
  ShakeDetector.swift    흔들기 감지 (감도 설정 반영)
  PanelController.swift  커서 중심 링 패널 띄우기
  PanelView.swift        360° 링 메뉴, 검색, 변환 모션
  PanelModel.swift       상태·드롭 처리
  Converter.swift        이미지·오디오·비디오·PDF 변환, 입력 검증, 안전한 저장
  Markdown.swift         마크다운 파서, 인쇄용 서식, HTML, 텍스트
  DocumentPDF.swift      머리글·바닥글이 있는 PDF 조판
  Settings*.swift        설정 저장소·설정 창, 로그인 항목
  Localization.swift     번역 헬퍼, 언어 선택
  AppMover.swift         DMG에서 실행 시 Applications로 옮기기
  Theme.swift            라이트/다크 단색 팔레트
Resources/               Info.plist, entitlements, 아이콘, DMG 배경, 번역(*.lproj)
scripts/                 빌드, DMG, 보안 검사, 번역 생성·검사, 아이콘·배경 생성
```

## 알려진 한계

- 컴파일과 실제 동작은 macOS에서만 확인할 수 있습니다 (CI가 macOS 러너에서 빌드를 검증합니다)
- 3채널 이상 오디오의 WAV/AIFF/CAF 변환, 암호 PDF는 미지원
- 애니메이션 GIF는 첫 프레임만 변환
- 문서 → Word 변환 시 표·코드 상자 같은 일부 서식은 Word에서 단순화될 수 있음
