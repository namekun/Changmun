<p align="center"><img src="docs/images/icon.png" width="120" alt="Changmun 아이콘"></p>

<h1 align="center">Changmun</h1>

<p align="center">
  <b>사이드바가 있는 가벼운 Mac 브라우저, 그리고 그걸 직접 쓰는 AI.</b><br>
  Safari와 같은 WebKit 엔진에, 왼쪽에는 세로 탭·즐겨찾기·북마크 폴더, 오른쪽에는 페이지를 읽고 클릭하고 입력해 주는 Claude 패널이 있다.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14%2B-black?logo=apple" alt="macOS 14 이상">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-555555" alt="MIT 라이선스"></a>
  <img src="https://img.shields.io/badge/Swift-native-orange?logo=swift&logoColor=white" alt="네이티브 Swift">
</p>

<p align="center">
  <a href="README.md">English</a> · <b>한국어</b> · <a href="README.ja.md">日本語</a> · <a href="README.zh-Hans.md">简体中文</a> · <a href="README.es.md">Español</a> · <a href="README.de.md">Deutsch</a> · <a href="README.fr.md">Français</a>
</p>

<p align="center">
  <img src="docs/images/window.png" width="760" alt="사이드바에 세로 탭이 있고 페이지 카드가 보이는 Changmun 창">
</p>

*Changmun*(창문)은 *window*를 뜻하는 우리말이다. 무료 오픈 소스이고, 계정도 추적도 없다. 앱은 영어, 한국어, 일본어, 중국어 간체, 스페인어, 독일어, 프랑스어로 쓸 수 있다.

## 설치

```sh
brew install --cask namekun/tap/changmun
```

[Homebrew](https://brew.sh)가 필요하고, macOS 14 Sonoma 이상의 Apple 실리콘 Mac에서 돌아간다. Homebrew가 격리 표시를 지워 주므로 앱이 바로 열린다. 업데이트는 `brew update && brew upgrade --cask changmun`.

처음 실행하면 지금 쓰는 브라우저의 북마크, 방문 기록, 비밀번호, 로그인 상태를 가져올지 묻는다.

### 소스에서 빌드

macOS 14 이상과 Xcode 또는 Command Line Tools가 필요하다.

```sh
git clone https://github.com/namekun/Changmun.git
cd Changmun
scripts/bundle.sh release   # makes build/Changmun.app
open build/Changmun.app
```

Command Line Tools만 깔려 있으면 스크립트가 macOS 26 SDK로 빌드한다(macOS 27 SDK의 SwiftUI 매크로 플러그인은 Xcode에만 있다). 빌드 결과물은 iCloud 데스크탑 동기화를 피해 `~/Library/Caches/Changmun/build`에 둔다.

## 하는 일

- **사이드바.** 즐겨찾기 타일, 북마크 폴더, 세로 탭. 탭은 끌어서 순서를 바꾸고, 즐겨찾기 위로 끌면 고정된다. 즐겨찾기와 북마크는 Dia·Arc처럼 저마다 자기 탭이 있어서, 누르면 보던 탭을 바꾸지 않고 그 탭으로 간다(⌘-클릭은 새 탭). 페이지의 링크를 사이드바로 끌어 놓으면 탭으로 열리고, 즐겨찾기나 폴더에 놓으면 그대로 저장된다. 탭 메뉴에서 새로고침, 복제, 새 창으로 옮기기, 공유, 다른 브라우저로 열기도 할 수 있다. 그룹의 탭을 모두 닫거나 북마크를 지운 뒤 몇 초 동안은 되돌릴 수 있다.
- **주소창 위치.** Arc처럼 사이드바 맨 위 뒤로·앞으로 버튼 아래, 또는 Dia처럼 페이지 위에 둔다: 설정 › 모양 › 주소창 위치. 사이트 이름만 보이고, 방패와 별은 포인터를 올리면 나온다. 즐겨찾기에 있는 페이지는 별이 늘 보이고, 눌러서 즐겨찾기에서 뺀다.
- **북마크 폴더.** 가져온 폴더는 원래 브라우저처럼 폴더 안에 폴더로 들어간다. 자주 쓰는 폴더는 사이드바에 고정해(우클릭이나 … › 사이드바에 고정, 또는 즐겨찾기 아래로 끌어 올리기) 그 자리에서 펼쳐 쓴다. 북마크를 다른 폴더나 즐겨찾기로 끌어다 놓거나, 메뉴의 옮기기로 옮긴다. 나머지 북마크는 사이드바 맨 아래 북마크 버튼에 검색칸과 함께 있고, 그 옆 … 버튼에서 방문 기록, 보관한 탭, 집중 모드, 설정을 연다.
- **탭 그룹.** 탭 우클릭 › 새 그룹으로 묶기, 이름을 붙이고 접는다. 그룹의 탭에서 새로 연 탭은 같은 그룹에 들어가고, 닫았다 다시 연 탭(⌘⇧T)은 원래 그룹으로 돌아간다.
- **탭 정리.** 새 탭 옆의 마술봉 버튼(윈도우 › 탭 정리)이 그룹에 없는 탭을 묶는다. Apple Intelligence가 켜져 있으면(macOS 26) 이 Mac 안의 모델이 주제별로 묶고 이름을 붙이며, 탭 정보는 Mac 밖으로 나가지 않는다. 쓸 수 없으면 한 탭에서 열어 간 탭끼리, 같은 사이트 탭끼리 묶는다. 정리한 뒤 몇 초 동안은 실행 취소로 되돌릴 수 있다. 주소창에서 새로 연 탭은 맞는 그룹에 저절로 들어간다(설정 › 탭에서 끈다).
- **오래 안 본 탭 보관**(기본은 끔). Changmun이 켜져 있는 동안 정한 시간(12시간~30일) 넘게 보지 않은 탭이 닫혀서 방문 기록 › 보관한 탭에 모이고, 원래 그룹으로 다시 열 수 있다. 화면에 보이는 탭, 재생 중인 탭, 화면 속 화면 탭, 카메라·마이크를 쓰는 탭, 즐겨찾기 탭, 개인 창의 탭은 보관하지 않는다.
- **분할 보기**(⌥⌘\\)는 탭 두 개를 나란히 보여 준다. **집중 모드**(⌘⇧F)는 페이지만 남기고 모두 숨긴다. **링크 미리보기**는 ⇧-클릭한 링크를 떠 있는 카드로 열고, ⌘↩를 누르면 탭으로 남는다.
- **개인 창**은 쿠키와 사이트 데이터를 메모리에만 두고 닫으면 지운다. 방문 기록, 세션, AI에는 아무것도 남기지 않는다.
- **명령 막대**(⌘T): 검색, 주소, 열린 탭으로 전환, 북마크·방문 기록, AI에게 묻기.
- **페이지 번역**은 macOS의 온디바이스 번역으로 그 자리에서 한다(⌥⌘T, macOS 26 이상). 링크와 배치는 그대로 두고, 글은 Mac 밖으로 나가지 않는다.
- **사이트 설정.** 주소창의 자물쇠와 사이트 이름을 누르면 그 사이트에 Changmun이 기억해 둔 것을 작은 창으로 모아 보여 준다: 광고 차단, 확대/축소, 팝업, 카메라·마이크, 탭을 재워도 되는지. 주소창의 다른 곳을 누르면 전처럼 주소를 고친다.
- **읽기 모드**(⇧⌘R, Chrome 방식 단축키에서는 ⌥⌘R)는 기사를 군더더기 없는 글로 페이지 위에 보여 준다. 기사로 보이는 페이지에서는 주소창에 버튼이 나온다. Esc나 ×, 같은 단축키를 누르면 페이지가 그대로 돌아온다. 페이지 안의 작은 스크립트로 처리하며, 내려받거나 어딘가로 보내는 것은 없다.
- **화면 속 화면**(⌃⌘P)은 영상이 재생 중인 탭에서 다른 탭으로 가면 저절로 켜진다. ⌃⌘← / ⌃⌘→로 5초씩 옮기는 건 다른 앱을 쓰는 중에도 되고, "탭으로 돌아가기"를 누르면 그 탭이 앞으로 나온다.
- **비밀번호**는 로그인한 뒤 키체인에 저장되고(https만), 주소창의 열쇠로 채운다. 복사하려면 Touch ID나 Mac 암호로 확인해야 한다.
- 클릭 없이 열리는 **팝업**은 막고, 페이지 바로 위에 "열기"와 "이 사이트는 항상 허용"을 띄운다.
- **다운로드**는 사이드바 아래에 진행률이 보이고, Safari처럼 격리 표시가 붙어서 처음 열 때 Gatekeeper가 검사한다. 앱·스크립트·설치 패키지는 실행하지 않고 Finder에서 보여 준다. 받다가 끊긴 다운로드는 그 행의 다시 시도로 멈춘 곳부터 이어 받는다.
- **탭 재우기.** 20분 넘게 보지 않은 백그라운드 탭과 메모리 압박 때의 백그라운드 탭은 웹 프로세스를 내려놓고, 다시 볼 때 방문 기록과 함께 복원한다.
- 페이지 확대 비율은 사이트별로 기억하고, 열린 탭은 15초마다 저장해서 비정상 종료돼도 거의 잃는 게 없다.
- **업데이트 알림.** Changmun은 Homebrew로 업데이트한다. 하루에 한 번 GitHub에서 최신 릴리스를 확인하고, 새 버전이 있으면 사이드바 아래에 조용한 알림이 떠서 `brew upgrade --cask changmun`을 복사해 준다. 설정 › 고급 › 업데이트 확인에서 끌 수 있다.

## 단축키

설정(⌘,)에서 Safari식과 Chrome식 중에 고른다. 두 브라우저가 다른 것만 다르다.

| 키 | 동작 |
| --- | --- |
| ⌘T / ⌘L | 명령 막대 / 현재 주소 편집 |
| ⌘E / ⌘⇧E | AI 패널 / 새 AI 대화 |
| ⌘D | 즐겨찾기 추가·제거 |
| ⌘N / ⌘⇧N / ⌘⇧W | 새 창 / 새 개인 창 / 창 닫기 |
| ⌘W, ⌘1–9, ⌘⇧[ ⌘⇧] | 탭 닫기, 사이드바 순서로 탭 이동 |
| ⌃Tab / ⌃⇧Tab | 최근에 본 순서로 탭 전환(⌃를 누른 채 Tab으로 고르고 떼면 이동, esc로 취소) |
| ⌥⌘\\ | 분할 보기 켜기·끄기 |
| ⇧-클릭 | 링크 미리보기: esc로 닫기, ⌘↩로 탭으로 열기 |
| ⌘⇧T | 닫은 탭 다시 열기(다시 열 탭이 없으면 닫은 창) |
| ⌃⌘M | 탭 음소거·소리 켜기 |
| ⌃⌘P | 화면 속 화면 켜기·끄기 |
| ⌃⌘← / ⌃⌘→ | 영상 5초 뒤로·앞으로 |
| ⌥⌘T | 페이지 번역·원문 보기 |
| ⌘F, ⌘G, ⌘⇧G | 페이지에서 찾기, 다음·이전 |
| ⌘Y | 방문 기록 |
| ⌘O, ⌘P, ⌘⇧C | 파일 열기, 인쇄, 주소 복사 |
| F12 또는 ⌥⌘I | 웹 인스펙터 |
| ⌘⇧F | 집중 모드 |

| 동작 | Safari식 | Chrome식 |
| --- | --- | --- |
| 사이드바 | ⌘⇧L | ⌘S |
| 강력 새로고침 | ⌥⌘R | ⌘⇧R |
| 읽기 모드 | ⇧⌘R | ⌥⌘R |
| 콘솔 | ⌥⌘C | ⌥⌘J |
| 다운로드 | ⌥⌘L | ⌘⇧J |
| 이전 탭 / 다음 탭 | | ⌥⌘← ⌥⌘→ |

## AI

오른쪽 패널(⌘E)은 이미 설치된 `claude` CLI를 쓰므로 Claude Code 구독으로 돌아간다. 기본 모델은 Sonnet이고, `defaults write io.github.namekun.Changmun aiModel opus`로 바꿀 수 있다.

AI는 다음 도구로 브라우저를 다룬다: `list_tabs`, `open_tab`, `switch_tab`, `close_tab`, `navigate`, `go_back`, `go_forward`, `reload`, `read_page`, `click`, `type_text`, `scroll`, `screenshot`. 비밀번호 칸은 읽지도 입력하지도 못한다.

페이지에 숨은 지시로 AI가 읽은 내용을 다른 곳에 빼돌리지 못하게, Changmun은 먼저 확인 창으로 묻는다(90초 동안 답이 없으면 거부).

- 보고 있지 않은 탭을 쓸 때: 탭과 그 사이트마다 한 번.
- 주소를 열 때: 검색, 이미 열렸거나 방문·북마크한 주소, 아는 사이트의 첫 화면이 아니면.
- 대화에서 다른 사이트를 읽은 뒤 입력할 때: 입력할 내용을 보여 주고 매번. 새 대화(⌘⇧E)에서 초기화.

Claude Code 같은 다른 에이전트도 MCP로 같은 도구를 쓸 수 있고, 같은 확인을 거친다.

```sh
claude mcp add changmun -- /Applications/Changmun.app/Contents/MacOS/Changmun --mcp
```

앱이 꺼져 있으면 `--mcp`가 Changmun을 먼저 띄운다. 제어 서버는 127.0.0.1에서만 열리고, 실행할 때마다 바뀌는 토큰이 필요하다.

셸에서 쓸 수도 있다. 명령을 실행할 수 있는 에이전트라면 무엇이든 쓴다(Homebrew가 `changmun`을 PATH에 넣는다).

```sh
changmun tabs
changmun open example.com
changmun read
changmun click 12
changmun type 3 "hello" --submit
```

나머지 명령은 `changmun help`에 있다. 명령마다 같은 도구를 하나씩 부르고, 같은 확인을 거치며, 필요하면 Changmun을 띄운다.

## 광고 차단

EasyList(광고)와 EasyPrivacy(추적)를 WebKit 콘텐츠 차단 규칙으로 바꿔 쓰고, 4일마다 새로 받는다. 설정 › 개인정보에서 목록을 끄거나 다른 목록을 주소로 더할 수 있다(한국 광고 목록은 한 번에 추가된다). 사이트가 깨지면 주소창의 방패 버튼으로 그 사이트만 끈다. WebKit이 표현할 수 없는 규칙(정규식, `$redirect`, 스크립틀릿, `:has-text` 같은 확장 선택자)은 잘못 막지 않도록 건너뛴다.

## 확장 프로그램

설정 › 확장에서 관리한다(웹 확장은 macOS 15.4 이상).

- **App Store의 Safari 확장**: 설치하면 목록에 저절로 나타나고, 켤 때 권한을 묻는다.
- **Chrome 웹 스토어 확장**: 스토어의 확장 페이지를 열면 페이지 위에 "Changmun에 추가"가 뜬다(설정에 주소나 ID를 넣어도 된다). 받은 확장은 `~/Library/Application Support/Changmun/Extensions`에 풀어 두고 WebKit 확장으로 불러온다. 다시 추가하면 업데이트된다.
- **Safari 콘텐츠 차단기**(Unicorn, AdGuard 등): macOS가 Safari 말고는 차단기에 규칙을 직접 요청하지 못하게 해서, 차단기가 저장해 둔 규칙 파일을 읽어 적용한다. 처음 켤 때 macOS가 다른 앱의 데이터 접근을 한 번 묻는다.
- 압축을 푼 확장 폴더(`manifest.json`)도 불러올 수 있다. 네이티브 앱과 주고받는 기능 등 일부는 동작하지 않을 수 있다.

## 다른 브라우저에서 가져오기

첫 실행 때(또는 메뉴에서) Safari와 크로미움 계열(Chrome, Arc(사이드바 포함), Dia, Aside, Whale, Brave, Edge, Vivaldi)에서 북마크와 방문 기록을 가져온다. 크로미움 계열에서는 비밀번호와 쿠키도 가져와서 로그인 상태가 그대로 유지된다.

- 비밀번호·쿠키는 각 브라우저의 키체인 항목(`<이름> Safe Storage`)으로 복호화하므로 macOS 허용 창이 뜬다. 가져온 비밀번호는 로그인 키체인에 `Changmun` 이름표로 저장된다.
- Safari는 전체 디스크 접근 권한이 있어야 읽을 수 있다. Safari 비밀번호는 macOS가 다른 앱에 내주지 않는다.

## 개인정보

- 웹 사용 내용은 이 Mac 안에만 있다. Changmun에는 계정도 서버도 분석 도구도 없다.
- 업데이트 확인은 하루에 한 번 GitHub의 공개 릴리스 API에서 최신 버전 번호만 가져오고 그 밖에는 아무것도 보내지 않는다(설정 › 고급에서 끌 수 있다).
- 검색어 추천은 명령 막대에 입력한 글자를 검색 엔진에 보낸다(설정에서 끌 수 있고, 개인 창에서는 보내지 않는다).
- AI 패널은 `claude` CLI를 통해 내가 쓴 메시지와 AI가 읽은 페이지 내용을 Anthropic에 보낸다. 탭 정리와 페이지 번역은 이 Mac 안에서 돈다.

## 개발자용

```sh
scripts/test.sh            # unit tests (Swift Testing)
scripts/check-strings.sh   # every string the code uses is translated in every language
swift scripts/make-icon.swift
scripts/release.sh 0.2.0 notes.md   # checks, DMG, GitHub release, Homebrew tap
```

UI 문구는 코드에서 영어이고 `Resources/<language>.lproj/Localizable.strings`에서 번역한다. 새 문구는 여섯 개 표 모두에 추가한다.

`scripts/headless.sh`는 테스트나 에이전트가 쓰는 화면 없는 Changmun을 띄운다. 창을 화면 밖에 두고, 포커스를 가져가거나 소리를 내지 않으며, `~/Library/Application Support/Changmun Headless`에 따로 프로필을 둔다. 키체인은 건드리지 않고, AI 확인 창·사이트 권한·JavaScript 대화상자는 알아서 처리한다(권한은 거부).

```sh
scripts/headless.sh start                                   # copy build/Changmun.app as the headless app and start it
scripts/headless.sh call open_tab '{"url": "example.com"}'  # the AI's tools: list_tabs, navigate, read_page, click…
scripts/headless.sh shot window.png                         # the whole window, sidebar included
scripts/headless.sh stop
```

## 라이선스

[MIT](LICENSE)
