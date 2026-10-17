# Changmun

Safari와 같은 WebKit 엔진으로 만든 가벼운 macOS 브라우저. 왼쪽 사이드바(즐겨찾기 타일, 북마크 폴더, 세로 탭)와 오른쪽 AI 패널이 있고, AI가 페이지를 읽고 클릭·입력·탭 조작을 할 수 있다.

## 빌드와 실행

```bash
scripts/bundle.sh release   # build/Changmun.app
open build/Changmun.app
scripts/test.sh             # 테스트
swift scripts/make-icon.swift        # Resources/AppIcon.icns (기본 시안 c, a·b도 있음)
```

## 단축키

| 키 | 동작 |
| --- | --- |
| ⌘T / ⌘L | 명령 막대(검색·주소·AI에게 묻기) / 현재 주소 편집 |
| ⌘E / ⌘⇧E | AI 패널 / 새 AI 대화 |
| ⌘S | 사이드바 접기 |
| ⌘D | 즐겨찾기 추가·제거 |
| ⌘W, ⌘1–9, ⌃Tab | 탭 닫기, 탭 이동 |

## AI

- 내장 패널은 설치된 `claude` CLI(Claude Code 구독)를 쓴다. 모델은 `defaults write io.github.namekun.Changmun aiModel opus`로 바꿀 수 있다(기본 sonnet).
- AI가 쓰는 도구: `list_tabs`, `open_tab`, `switch_tab`, `close_tab`, `navigate`, `go_back`, `go_forward`, `reload`, `read_page`, `click`, `type_text`, `scroll`, `screenshot`. 비밀번호 칸은 읽지도 입력하지도 못한다.
- 페이지에 숨은 지시로 AI가 다른 곳에서 읽은 내용을 빼돌리지 못하게, 앱이 확인 창으로 묻는 경우가 있다(90초 동안 답이 없으면 거부).
  - 보고 있지 않은 탭을 쓸 때: 탭과 그 사이트마다 한 번.
  - 주소를 열 때: 검색 엔진 검색, 이미 열렸거나 방문·북마크한 주소 그대로, 아는 사이트의 첫 화면이 아니면 주소마다.
  - 입력할 때: 이 대화에서 다른 사이트를 읽은 뒤라면 입력할 내용을 보여 주고 매번. 새 대화(⌘⇧E)에서 초기화.
- 다른 에이전트(Claude Code 등)에서도 같은 도구를 쓸 수 있고, 같은 확인을 거친다.

```bash
claude mcp add changmun -- /Applications/Changmun.app/Contents/MacOS/Changmun --mcp
```

앱이 꺼져 있으면 `--mcp`가 앱을 먼저 띄운다. 제어 서버는 127.0.0.1에서만 열리고, 실행할 때마다 바뀌는 토큰이 필요하다.

## 메모리

- 오래 안 본 백그라운드 탭(기본 20분, `sleepTabsAfterMinutes`)과 메모리 압박 때의 백그라운드 탭은 웹 프로세스를 내려놓고, 다시 볼 때 방문 기록과 함께 복원한다.

## 다른 브라우저에서 가져오기

첫 실행 때(또는 메뉴 › 다른 브라우저에서 가져오기) Chrome, Arc(사이드바 고정 탭 포함), Dia, Aside, Whale, Brave, Edge, Vivaldi 같은 크로미움 계열과 Safari에서 북마크·방문 기록을 가져온다. 크로미움 계열에서는 비밀번호와 쿠키(로그인 상태)도 가져온다.

- 비밀번호·쿠키는 각 브라우저의 키체인 항목(`<이름> Safe Storage`)으로 복호화하므로 macOS 허용 창이 뜬다. 가져온 비밀번호는 로그인 키체인에 `Changmun` 이름표로 저장되고, 로그인 칸이 있는 페이지에서 주소 옆 열쇠 버튼으로 채운다.
- Safari는 전체 디스크 접근 권한이 있어야 읽을 수 있다. Safari 비밀번호는 macOS가 다른 앱에 내주지 않는다.
