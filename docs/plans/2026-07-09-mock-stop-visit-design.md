# Mock StopVisit 발생 (Admin, 로컬 전용) 설계

작성일: 2026-07-09
브랜치: `feature/traccar-geofence-events`

## 목적

실제 Traccar 서버 없이, Admin 화면 버튼 한 번으로 특정 정류장에 `StopVisit(enter)`를
발생시켜 시민 진행바의 버스 아이콘이 그 정류장으로 이동하는 것을 눈으로 확인한다.

`StopsController#current_bus_stop`은 `trip.stop_visits`의 최신 `occurred_at` visit의 stop을
버스 현위치로 판정한다(event_type 무관, `stops_controller.rb:234`). 따라서 대상 Stop에
`enter` visit 하나만 꽂으면 아이콘이 이동한다 — exit 버튼은 불필요(YAGNI).

## 결정 사항

- **Mock 경로**: Admin 액션에서 `StopVisit.create!` 직접 호출 (웹훅 경로 아님).
  웹훅 파싱/인증/ID 매칭 경로는 이 mock의 범위 밖.
- **안전 범위**: production/staging 노출 금지. 가짜 StopVisit이 시민 도착정보에 직접 반영되므로.
  - 라우트를 `if Rails.env.local?`(development + test)로 게이트한다. 기존 `debug_bus`가
    라우트 레벨에서 `Rails.env.development?`로 막는 패턴(`routes.rb:40`)을 따르되, 컨트롤러
    테스트로 로직을 커버하기 위해 test까지 포함하는 `local?`을 쓴다. production/staging 제외.
  - 액션 진입부에도 같은 가드를 방어적으로 둔다.
- **Trip 연결**: 활성 trip(ended_at IS NULL)이 없으면 자동 생성(`started_at: Time.current`).
  기존 `positions`/`events` 수신 로직과 동일한 규칙(사용자 확인 완료).
- **event_type**: `"enter"` 고정.

## 구현

### 라우트 (`config/routes.rb`)

admin `resources :stops` member 블록을 `local?`일 때만 `mock_visit`를 추가하도록 확장:

```ruby
resources :stops do
  member do
    post :sync_geofence
    post :mock_visit if Rails.env.local?
  end
end
```

### 컨트롤러 (`Admin::StopsController#mock_visit`)

- `before_action :set_stop`에 `mock_visit` 추가.
- 로직:
  1. `return head :not_found unless Rails.env.local?` (방어적 가드)
  2. `bus = @stop.route&.bus` — nil이면 `flash[:alert]` 후 redirect (노선에 버스 미배정)
  3. 활성 trip 조회, 없으면 `bus.trips.create!(started_at: Time.current)`
  4. `trip.stop_visits.create!(stop: @stop, event_type: "enter", occurred_at: Time.current)`
     - `ActiveRecord::RecordNotUnique`(같은 초 중복 클릭, uniqueness scope 충돌) → rescue,
       조용히 넘어감(이미 그 정류장에 visit이 있으므로 목적 달성)
  5. `redirect_to admin_stop_path(@stop), notice: "#{@stop.name}에 버스 도착(mock)을 발생시켰습니다."`

### 뷰 (`app/views/admin/stops/show.html.erb`)

기존 `sync_geofence` 버튼 옆, `Rails.env.local?`일 때만 노출. 실데이터 버튼과 구분되게
다른 색(amber)으로:

```erb
<% if Rails.env.local? %>
  <%= button_to "버스 도착 mock", mock_visit_admin_stop_path(@stop), method: :post,
        class: "px-4 py-2 rounded-lg bg-amber-500 text-white text-sm font-medium hover:bg-amber-600" %>
<% end %>
```

## 테스트 (`test/controllers/admin/stops_controller_test.rb`)

- mock_visit → 활성 trip 없을 때: StopVisit +1, Trip +1 생성, 정상 redirect + notice
- mock_visit → 활성 trip 있을 때: 그 trip에 StopVisit +1, Trip 미증가
- 노선에 버스 미배정: alert flash, StopVisit 미생성
- (환경 가드는 test에서 `local? == true`라 통과하므로, production 차단은 코드 리뷰로 확인)

## 검증

`bin/rails server` → Admin 각 정류장 상세에서 "버스 도착 mock" 클릭 →
시민 페이지 `/r/:region_slug/:stop_id`에서 진행바 아이콘이 해당 정류장으로 이동(5초 폴링) 확인.

## 범위 밖 (의도적 제외)

- 웹훅(`Integrations::TraccarController#events`) 경로를 통한 mock (선택지 A) — 이번엔 안 함.
- exit 이벤트 mock — current_bus_stop이 event_type 무관이라 불필요.
- 시민 화면에 StopVisit 표시 자체(이미 `current_bus_stop`으로 반영됨 — 이 mock은 그걸 눈으로 확인하는 도구).
