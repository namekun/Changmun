<p align="center"><img src="docs/images/icon.png" width="120" alt="Changmun 아이콘"></p>

<h1 align="center">Changmun</h1>

<p align="center">
  <b>사이드바가 달린 가벼운 Mac 브라우저. AI가 직접 쓰기도 해요.</b><br>
  Safari와 같은 WebKit 엔진 위에, 왼쪽에는 세로 탭·즐겨찾기·북마크 폴더를, 오른쪽에는 페이지를 읽고 클릭하고 입력까지 해 주는 Claude 패널을 얹었어요.
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

*Changmun*은 우리말 "창문"에서 따온 이름이에요. 무료 오픈 소스이고, 계정이 필요 없어요. 앱은 영어, 한국어, 일본어, 중국어 간체, 스페인어, 독일어, 프랑스어를 지원해요.

## 설치

```sh
brew install --cask namekun/tap/changmun
```

아니면 [앱을 바로 내려받아도](https://github.com/namekun/Changmun/releases/latest/download/Changmun.dmg) 돼요.

- Apple 실리콘 Mac에서 macOS 14 이상이 필요해요.
- Apple의 서명과 공증을 받아서 바로 열려요.
- 스스로 업데이트해요.
- 처음 실행하면 북마크와 방문 기록을 가져올지 물어봐요.

## 왜 Changmun인가

- **가벼워요.** 앱은 21MB, 내려받는 크기는 약 7MB예요. Mac에 이미 들어 있는 WebKit 엔진을 써요.
- **사이드바가 있어요.** 세로 탭, 즐겨찾기, 북마크 폴더, 탭 그룹, 스페이스가 한 열에 모여 있어요. 탭을 위쪽에 두고 싶다면 설정에서 바꿀 수 있어요.
- **브라우저를 쓰는 AI.** Claude가 페이지를 읽고, 대신 클릭하고 입력해요. 위험한 동작 앞에서는 먼저 물어봐요.
- **개인정보를 지켜요.** 계정도 서버도 분석 도구도 없어요. 광고와 추적기는 처음부터 막아 줘요.
- **쓰던 것도 가져와요.** Safari와 Chromium 계열 브라우저에서 북마크와 방문 기록을, Chromium 계열에서는 비밀번호도 가져와요.
- **나만의 시작 페이지.** 스타일은 세 가지이고, 구성 요소는 마음대로 배치하고, 배경도 직접 고를 수 있어요.

## AI

⌘E를 누르고 평소 말하듯이 부탁해 보세요.

- "이 페이지를 요약해 줘."
- "이 탭 세 개의 가격을 비교해 줘."
- "이 사이트에 로그인해 줘."

이미 설치한 `claude` CLI로 돌아가요. 그래서 본인의 Claude Code 구독을 써요. Claude를 쓰지 않는다면 패널은 무시해도 돼요. 브라우저의 나머지 기능은 AI 없이도 다 쓸 수 있어요.

**안전장치**

- 결제, 전송, 게시, 삭제 전에는 먼저 물어봐요.
- 지금 보지 않는 탭을 쓰거나 처음 보는 사이트를 열기 전에도 먼저 물어봐요.
- 비밀번호는 볼 수 없고, 개인 창은 아예 보지 못해요.

메시지, 첨부한 이미지, AI가 읽은 페이지는 `claude` CLI를 거쳐 Anthropic으로 전달돼요. 다른 도구도 MCP나 `changmun` 명령으로 Changmun을 조작할 수 있어요.

## 헤드리스 모드

AI 에이전트와 스크립트를 위한, 창이 없는 두 번째 Changmun이에요. 화면에 나타나지 않고, 포커스를 가져가지 않고, 소리도 내지 않아요.

```sh
changmun headless start
changmun --headless open example.com
changmun --headless read
changmun headless stop
```

Claude Code에 연결하려면:

```sh
claude mcp add changmun-headless -- /Applications/Changmun.app/Contents/MacOS/Changmun --mcp --headless
```

- **내 브라우저와 분리돼요.** 빈 프로필을 따로 쓰기 때문에 쿠키, 방문 기록, 비밀번호, 키체인이 들어 있지 않아요.
- **묻지 않아요.** 평소의 승인 질문이 꺼져 있어서 에이전트가 멈추지 않고 일할 수 있어요.
- **되돌릴 수 없는 일은 멈춰요.** 결제, 주문, 전송, 게시, 삭제, 접근 허용처럼 보이는 동작은 "사람이 필요하다"는 오류가 나요.

[헤드리스 모드 자세히 보기](GUIDE.ko.md#에이전트용-화면-없는-changmun)

## 다른 브라우저와 비교

Changmun이 모든 면에서 모든 브라우저를 이기려는 건 아니에요. 어디가 다르고, 어떤 경우에 다른 브라우저가 더 나은지 정리했어요.

| | 앱 크기 | 엔진 |
| :-- | --: | :-- |
| **Changmun 0.10.2** | **21MB** | WebKit, macOS에 들어 있는 것 |
| Safari 27 | 35MB | WebKit, macOS에 들어 있는 것 |
| Google Chrome 156 | 731MB | Chromium, 자체 사본 |
| Arc 1.168 | 862MB | Chromium, 자체 사본 |
| Dia 1.53 | 1.3GB | Chromium, 자체 사본 |

<sub>2026년 10월에 Apple 실리콘 Mac 한 대에서 `du -sh`로 쟀어요.</sub>

| 비교 대상 | Changmun이 주는 것 | 이런 경우엔 그 브라우저를 계속 쓰세요 |
| :-- | :-- | :-- |
| **Safari** | 같은 엔진에 세로 탭이 있는 사이드바, 페이지를 대신 다뤄 주는 AI, Chrome 웹 스토어 확장이 더해져요 | 탭, 비밀번호, 패스키의 iCloud 동기화가 필요할 때 |
| **Chrome** | Google 계정도 동기화 서버도 없고, 앱 크기는 Chrome의 약 3%예요 | Chromium 전용으로 만든 사이트, Chrome 동기화, Windows·Linux·휴대폰이 필요할 때 |
| **Arc** | 같은 사이드바·스페이스 발상이고, 기능도 계속 늘어나요(Arc는 2025년 5월부터 유지보수 모드예요) | Boosts나 Easels가 필요할 때 |
| **Dia** | 같은 계열의 발상이지만, 자체 AI 서비스도 계정도 없어요. 설치된 `claude` CLI를 써요 | Dia의 호스팅 AI 기능과 업무용 연동이 필요할 때 |

이 내용은 각 프로젝트가 스스로 밝힌 내용이에요. 오래된 부분이 있다면 [이슈를 열어](https://github.com/namekun/Changmun/issues) 알려 주세요.

### 아직 없는 것

- **동기화가 없어요.** 북마크, 방문 기록, 비밀번호는 만든 Mac에만 남아요.
- **Mac 전용이에요.** iPhone, Windows, Linux는 지원하지 않아요.
- **패스키는 아직이에요.** 브라우저가 패스키를 쓰려면 Apple의 권한(entitlement)이 필요해요. Changmun은 신청해 두고 기다리는 중이에요.
- **확장은 macOS 15.4 이상이 필요해요.** 일부 Chrome 확장은 WebKit에 없는 기능에 기대요.
- **Chromium 전용 사이트**는 Safari에서처럼 여기서도 제대로 동작하지 않을 수 있어요.
- **만드는 사람이 한 명이에요.** 들여다보는 눈이 큰 브라우저보다 적고, 거친 구석도 그만큼 있어요. 버그 제보는 언제든 환영해요.

## 알아 두면 좋은 단축키

| 키 | 하는 일 |
| :-- | :-- |
| ⌘T | 새 탭 |
| ⌘L | 주소 편집 |
| ⌘E | AI 패널 |
| ⌘D | 즐겨찾기 추가·제거 |
| ⌃1–9 | 스페이스로 이동 |
| ⌥⌘\\ | 분할 보기 |
| 링크를 ⇧-클릭 | 보던 페이지를 떠나지 않고 미리보기 |
| ⌘⇧T | 닫은 탭 다시 열기 |

Safari식 키와 Chrome식 키 중에서 설정(⌘,)에서 고를 수 있어요. [모든 단축키](GUIDE.ko.md#단축키)는 가이드에 있어요.

## 개인정보

탐색 내용은 Mac 안에만 남아요. 앱이 스스로 보내는 요청은 업데이트 확인, 광고 필터 목록 새로 받기처럼 몇 가지뿐이에요. 검색어 제안은 입력한 내용을 검색 엔진에 보내요. 끌 수 있고, 개인 창에서는 아예 보내지 않아요. [무엇을 언제 보내는지 전부 보기](GUIDE.ko.md#개인정보).

## 더 알아보기

[가이드](GUIDE.ko.md)에 모든 내용이 자세히 있어요.

- [기능](GUIDE.ko.md#하는-일): 탭, 스페이스, 읽기 모드, 개인 창, 다운로드
- [AI](GUIDE.ko.md#ai): 모델, 승인, 도구, MCP와 명령줄
- [광고 차단](GUIDE.ko.md#광고-차단), [확장 프로그램](GUIDE.ko.md#확장-프로그램), [다른 브라우저에서 가져오기](GUIDE.ko.md#다른-브라우저에서-가져오기)
- [비밀번호와 보안](GUIDE.ko.md#비밀번호와-보안)
- [개발자용](GUIDE.ko.md#개발자용)과 [소스에서 빌드](GUIDE.ko.md#소스에서-빌드)

## 라이선스

MIT예요. [LICENSE](LICENSE)를 보세요.
