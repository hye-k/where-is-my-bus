> 이 파일은 `/.claude/`가 `.gitignore` 대상이라 git에 올라가지 않음. 다른 장비에서 이어서 작업하려면 `docs/session-handoff.md`(같은 내용, git 추적됨)를 참고할 것 — 갱신할 때 두 파일 모두 반영.

# 다음 세션 인수인계 — Traccar Geofence 동기화 브랜치

마지막 업데이트: 2026-07-09 (같은 날 두 번째 세션)

## 2026-07-09 세션 2 — 진행 중, 미완성 (다음 세션은 여기부터)

### 이번 세션 목표

`/r/:region_slug/:stop_id` 페이지에서 StopVisit 이벤트로 진행바의 버스 아이콘(SVG, `data-arrival-polling-target="busMarker"`, `app/views/stops/show.html.erb`)이 실제로 움직이는 것을 눈으로 확인하는 것. StopVisit은 실제 Traccar 서버 없이 Mock 데이터로 발생시켜도 된다는 전제. Admin 화면에서 버튼으로 mock을 발생시키는 방식을 논의했으나 **구현 착수 전 상태로 세션이 끝남 — 코드 변경 없음.**

### 확인된 사실 (근거 있는 것만)

- Admin 로그인 계정: `hyewon.k.developer@gmail.com`, `role: operator`. 비밀번호를 몰라서 이번 세션에서 개발용으로 재설정함(`bin/rails runner`로 `User#update!(password: ...)` 직접 호출) — 재설정한 값은 이 문서에 기록하지 않음(공개 저장소에 올라가는 문서라서). 다시 필요하면 같은 방식으로 재설정하면 됨.
- 팀원이 실제 운영 환경(다른 프로젝트/서버로 추정, n8n 워크플로우 `https://n8n.newstapadatalab.org/webhook/traccar-events`)에서 캡처된 Traccar geofence 이벤트 웹훅 로그 예시를 제공함. 이 로그는 n8n이 수신 요청 전체를 감싼 형태로, 최상위에 `headers`/`params`/`query`/`body`/`webhookUrl` 키가 있고, Traccar가 실제로 보낸 것으로 보이는 내용은 `body` 키 안쪽(`event`/`position`/`device`/`geofence`)에 있음.
  - `body.event` 예시: `{"id":58,"deviceId":1,"type":"geofenceEnter","eventTime":"2026-07-04T10:20:11.000+00:00","positionId":17142,"geofenceId":33,"maintenanceId":0}` (exit 이벤트는 `type:"geofenceExit"`로 별도 존재)
  - `body.device.uniqueId`: `"50899200"` (이 프로젝트의 어느 Bus 레코드와도 연결된 적 없는, 팀원 쪽 환경의 값)
  - `body.geofence`: `{"id":33,"name":"지오펜스 테스트h","area":"POLYGON(...)"}`
  - **미확인**: 이 `body` 안쪽 구조가 우리 Rails 서버(`Integrations::TraccarController#events`)가 실제로 받는 HTTP 바디와 정확히 같은 형태인지는 확인하지 못함. n8n이 중간에 추가로 감쌌을 수도, 그대로 전달할 수도 있음 — 팀원에게 재확인 필요.
- `Integrations::TraccarController#events`(`app/controllers/integrations/traccar_controller.rb`)는 최상위에 `event`/`device` 키가 바로 있는 형태를 기대함(`params[:event]`, `params.dig(:device, :uniqueId)`). 팀원이 준 로그의 `body` 바깥 껍데기(`headers`/`params`/`query`/`webhookUrl`)는 이 컨트롤러가 기대하는 구조와 다름.
- 이 컨트롤러의 매칭 로직: `Stop.find_by(traccar_geofence_id: event[:geofenceId])`, `Bus.find_by(traccar_unique_id: params.dig(:device, :uniqueId))` — 둘 다 못 찾으면 조용히 200 ack하고 아무 것도 안 함(재시도 폭주 방지 목적, 의도된 동작).
- 개발 DB(`storage/development.sqlite3`) 현재 상태(직접 조회 확인):
  - `Stop` 8개 전부 `traccar_geofence_id: nil`
  - `Bus#1`(경남 70 가 1234): `traccar_unique_id: "goseong-1-demo"`, **`traccar_device_id: nil`**
- `TraccarGeofenceSync.call(stop)`(`app/services/traccar_geofence_sync.rb`)은 `bus&.traccar_device_id`가 없으면 Traccar API 호출 자체를 하지 않고 `Result.new(success: true)`로 조용히 스킵한다(코드: `return Result.new(success: true) unless bus&.traccar_device_id`). `traccar_device_id`는 "이 geofence를 어느 Traccar device에 연결할지"(`link_device` 호출 대상)를 가리키는 값이고, `traccar_unique_id`(GPS position 수신 시 버스를 식별하는 값)와는 다른 필드/다른 용도.
  - 따라서 **개발 DB에 새 Stop을 만들거나 기존 Stop을 수정해도, `Bus#1`의 `traccar_device_id`가 `nil`인 한 `traccar_geofence_id`는 자동으로 채워지지 않는다.** ("테스트용 Stop을 만들면 geofence도 자동 생성되지 않을까"라는 가설은 이 환경에서는 근거가 없음 — 실측으로 반증됨.)

### 아직 결정되지 않은 것 (다음 세션에서 먼저 정할 것)

1. **Mock을 어느 경로로 발생시킬지 미확정.** 두 가지 안이 논의만 되고 선택되지 않음:
   - (A) `Integrations::TraccarController#events` 웹훅 경로를 실제로 태우기 — 더 실제와 가깝지만, 위 "미확인" 항목(n8n `body` 구조 재확인) 및 `traccar_geofence_id`/`traccar_device_id` 부재 문제를 먼저 해결해야 함(예: 개발용으로 임의 값을 미리 채워 넣는 절차 필요, 그 절차 자체는 아직 설계 안 됨).
   - (B) `StopVisit.create!`를 Admin 액션에서 직접 호출 — 구현은 더 간단하지만 웹훅 파싱/인증/ID 매칭 경로는 전혀 검증되지 않음.
   - 사용자에게 두 차례 이 선택지를 물었으나 응답 없이 세션이 끊김. **다음 세션 시작하면 이것부터 확인.**
2. Mock 버튼을 Admin의 어디에 둘지(Admin::Stops#show 화면에 `sync_geofence`와 같은 패턴으로 버튼 추가하는 방향까지는 논의했으나 최종 확정 아님).
3. mock으로 만든 StopVisit을 어느 trip에 붙일지는 확정: **활성 trip이 없으면 자동으로 새 trip 생성**(사용자 확인 완료, `started_at: Time.current`) — 이 부분만 결정됨.

### 코드 변경 사항

**없음.** 이번 세션 2에서는 조사/논의만 하고 실제 코드/문서 변경은 이 HANDOFF.md 갱신이 유일함. 세션 1(위 "2026-07-09 세션에서 한 일")의 커밋 `856ee7c`가 이 브랜치의 마지막 코드 커밋.

---

## 2026-07-09 세션 1에서 한 일

"GPS/geofence 우선순위 재설계"(아래 옛 "다음에 할 일 1번" 항목)를 이 브랜치 위에서 진행하기로 확정하고 완료함:
- `superpowers:brainstorming`으로 설계 확정 → `docs/plans/2026-07-09-gps-geofence-priority-design.md`
- TDD로 구현: `StopsController#arrival`/`#detail`의 `bus_stop` 판정을 GPS 최근접 계산 단독에서 "StopVisit 우선, 없으면 GPS fallback"으로 전환하는 `current_bus_stop` 헬퍼 추가. `progress`/`bar_pct` 보간은 GPS 기반 그대로 유지. `debug_bus`는 범위에서 제외(강제 시뮬레이션 도구라서).
- `/code-review` high effort로 검토(8개 각도, 5개 후보 검증) → 정확성 버그 없음, 낮은 심각도 altitude 이슈 1건(설계 문서의 debug_bus 언급 오류)만 발견 → 문서 정정으로 반영
- 커밋 `856ee7c`로 반영, 테스트 29개 전부 통과, rubocop 클린

**아래 "지금 상태"의 브랜치 커밋 3개 목록은 이제 4개로 갱신됨(위 커밋 추가). 브랜치 마무리(merge/PR/보류) 여부는 여전히 미결.**

## 지금 상태

- **브랜치**: `feature/traccar-geofence-events` (아직 main에 병합 안 됨, PR도 안 만듦)
- **백업 브랜치**: `backup/traccar-geofence-events-before-squash` — 리뷰 findings 수정 과정을 커밋 단위로 세세히 보고 싶으면 여기서 원본 17개 커밋 이력 참조 가능. 정리 끝나면 삭제해도 무방.
- 커밋 3개로 정리 완료:
  1. `f93a39a` docs: 설계 문서 + Minitest/WebMock 테스트 인프라 셋업
  2. `6592eb4` feat: Stop geofence 동기화(Traccar) + geofence 이벤트 수신 핵심 구현
  3. `67a397a` fix: 코드 리뷰 findings 7건 반영
- 테스트 24개 전부 통과. 이 브랜치가 작성한 코드(`app/`, `test/`, 이번에 추가한 `db/migrate/*.rb` 2개)는 rubocop 클린. 단, `bin/rubocop`을 저장소 전체에 돌리면 18개 offense가 나오는데, 전부 `main`에도 이미 있던 기존 마이그레이션 파일들(`db/migrate/20260605...create_areas.rb` 등, `Layout/SpaceInsideArrayLiteralBrackets`)에서 나는 것 — 이번 브랜치 책임 아니니 무시해도 됨.
- 로컬 개발 서버가 백그라운드에서 계속 떠 있을 수 있음 (`http://localhost:3000`) — 새 세션에서 다시 붙일 땐 `ps aux | grep puma`로 살아있는지 먼저 확인

## 이번 브랜치가 한 일 (요약)

`docs/traccar-integration.md`와 `docs/plans/2026-07-02-stop-geofence-events-design.md`에 전체 설계가 있음. 요점만:

- **Outbound**: Admin에서 Stop을 CRUD하면 `TraccarGeofenceSync` 서비스가 Traccar REST API에 정류장 좌표 기준 사각형(변 30m) geofence를 생성/수정/삭제하고, 그 노선에 배정된 버스(`route.bus`)의 Traccar device에 연결. 실패해도 예외를 던지지 않고 `Result` 객체로 반환 → admin 화면에 flash 경고만 뜨고 Stop 저장 자체는 유지됨. Stop 상세 화면에 "Traccar 동기화 재시도" 버튼 있음.
- **Inbound**: `POST /integrations/traccar/events` — 기존 position 수신과 같은 `X-Ingest-Token` 인증 재사용. geofence 진입/이탈 이벤트를 받아 `StopVisit`(신규 모델)에 저장. 활성 Trip이 없으면 `positions`와 동일하게 자동 생성.

## 로컬 환경 재현 방법

이 저장소는 Ruby 4.0.2를 asdf로 관리하는데, macOS 시스템 기본 Ruby는 2.6이라 매번 PATH를 명시적으로 잡아줘야 함:

```bash
export PATH="$HOME/.asdf/shims:/opt/homebrew/opt/asdf/bin:$PATH"
cd /Users/hyewon/projects/where-is-my-bus
bin/rails test        # 전체 테스트
bin/rails server       # 개발 서버 (bin/dev의 tailwindcss:watch는 이 macOS 환경에서 즉시 종료되는 문제가 있어 못 씀 — 아래 "알려진 로컬 환경 이슈" 참고)
```

`bin/dev`(foreman으로 서버+tailwind watch 동시 실행)는 이 환경에서 안 됨. `bin/rails tailwindcss:build`로 CSS를 한 번 빌드해두고 `bin/rails server`만 단독 실행하는 우회법을 씀. CSS를 만지는 작업이 생기면 이 watch 문제부터 별도로 조사 필요(맥OS 보안/권한 문제로 추정, 아직 원인 미규명).

## 다음에 할 일 — 우선순위 순

### 1. ~~GPS position vs geofence event 우선순위 재설계~~ — 2026-07-09 세션에서 완료

(완료 내용은 위 "2026-07-09 세션에서 한 일" 참고)

### 2. 브랜치 마무리 (사용자에게 아직 답 못 받음)

세션 종료 시점에 `finishing-a-development-branch` 옵션 4개를 제시했었는데 답을 못 받고 세션이 끝남:
1. Merge back to main locally
2. Push and create a Pull Request
3. Keep the branch as-is
4. Discard this work

**다음 세션 시작하면 이것부터 물어봐야 함.** 위 "GPS/geofence 재설계" 작업을 이 브랜치 위에서 계속할지, merge 후 새 브랜치로 시작할지도 이 답변에 달려있음.

### 3. 운영 환경 설정 (이번 브랜치 코드가 요구하지만 아직 안 채워짐)

실제 배포/운영 테스트를 하려면 아래가 필요함 — 코드는 이미 이걸 전제로 짜여 있음:

```bash
bin/rails credentials:edit
```
```yaml
traccar:
  ingest_token: <inbound 웹훅 인증 토큰>
  api_base_url: <Traccar 서버 API 주소, 예: http://localhost:8082>
  api_email: <Traccar 관리자 계정 이메일>
  api_password: <Traccar 관리자 계정 비밀번호>
```

지금 개발 DB엔 이 credentials가 비어있어서 `TraccarGeofenceSync.call`을 실제로 호출하면 에러 메시지가 좀 불친절함(`URI.join(nil, path)` 실패로 "bad argument (expected URI object or URI string)"). 실제 Traccar 서버가 준비되기 전까지는 이 상태로 괜찮음 — 테스트는 전부 `stub_credentials`로 이 의존성을 우회하고 있어서 credentials 없이도 통과함.

### 4. 알려진 남은 제약 (설계 문서에 명시된, 의도적으로 범위 밖으로 미룬 것들)

- **Route-Bus 1:N 전환**: 지금 `Route belongs_to :bus`(1노선:1버스, `optional: true`)로 되어 있는데, 실제로는 한 노선에 여러 버스가 배차될 수 있어야 함(배차 간격 유지). 이번 브랜치는 이 잘못된 전제 위에서 그냥 진행했음 — 별도 마이그레이션 작업 필요. `route.bus`를 참조하는 곳(`TraccarGeofenceSync`, `stops_controller.rb`의 ETA 계산 로직 등) 전부 영향받음.
- **시민 화면에 StopVisit 반영**: 지금은 `StopVisit`을 저장만 하고 시민용 도착정보 페이지(`/r/:region_slug/:stop_id`)에는 아직 안 보여줌. "1. GPS/geofence 우선순위 재설계"와 자연스럽게 묶일 작업.
- **차량 등록 시 Traccar 디바이스 자동 프로비저닝**: 지금은 `bus.traccar_device_id`/`traccar_unique_id`를 수동으로 채워야 함. `docs/traccar-integration.md` 로드맵 2단계.

## 참고 문서

- `docs/traccar-integration.md` — Traccar 연동 전체 설계 + 운영 설정 가이드(가장 먼저 읽을 문서)
- `docs/plans/2026-07-02-stop-geofence-events-design.md` — 이번 기능의 브레인스토밍 결과 설계 문서(결정 사항과 그 이유)
- 구현 계획 문서(`2026-07-02-stop-geofence-events-plan.md`)는 구현 완료 후 커밋에서 제외함(더 이상 유효하지 않으므로) — 필요하면 `backup/traccar-geofence-events-before-squash` 브랜치의 초기 커밋들에 남아있음
