# Stop Geofence 동기화 + geofence 이벤트 수신 설계

## 배경

`docs/traccar-integration.md`(Phase 1)로 position forwarding은 이미 연동되어 있다. 이번 작업은 Stop(정류장) 좌표를 기준으로 Traccar geofence를 관리자 CRUD 시 동기화하고, geofence 진입/이탈 이벤트를 수신해 저장하는 Phase를 추가한다.

## 범위

- **A. Outbound (Rails → Traccar)**: Admin Stop CRUD 시 사각형 geofence를 Traccar에 생성/수정/삭제하고 `route.bus`에 연결.
- **B. Inbound (Traccar → Rails)**: geofence 진입/이탈 웹훅을 받아 `StopVisit`으로 저장.
- **범위 밖**: 시민 화면(도착정보 페이지)에 이 데이터를 반영하는 것은 별도 작업. Route-Bus 관계를 1:N으로 바로잡는 마이그레이션도 별도 작업 — 이번엔 현재 구조(`Route belongs_to :bus`, 1:1)를 그대로 전제로 한다.

## 결정 사항

1. **Geofence 형태**: 사각형, 정류장 좌표 중심으로 변 30m 고정 상수(`TraccarGeofenceSync::SIDE_METERS`). 위도 1도≈111km 근사 + 경도 `cos(lat)` 보정으로 계산(30m 규모에서 오차 무시 가능, 별도 geo 라이브러리 불필요).
2. **Geofence-Bus 연결**: `stop.route.bus`(1:1 구조) 하나에 연결. `route.bus`가 nil(버스 미배정)이면 조용히 스킵 — Stop 저장 자체는 항상 성공.
3. **이벤트 저장**: 새 `StopVisit` 모델(`stop_id`, `trip_id`, `event_type` enter/exit, `occurred_at`). 기존 `Trip`/`GpsLog` 패턴(활성 trip 조회)을 재사용.
4. **이벤트 수신 방식**: Event Forwarding(웹훅) — REST API 폴링 대비 기존 position 수신과 패턴이 같아 일관적이고, MVP 단계에서 새 백그라운드 인프라(Solid Queue recurring job)를 추가하지 않아도 됨. 유실 시에도 동시점의 GpsLog가 안전망 역할.
5. **인증**: 기존 `X-Ingest-Token` 공유(`Integrations::TraccarController#authenticate_ingest!` 재사용).
6. **Outbound 동기화 실행 위치**: Stop 모델 콜백이 아니라 `Admin::StopsController`에서 직접 `TraccarGeofenceSync.call(@stop)` 호출. 실패해도 Stop 저장은 성공시키되, admin에게 flash 경고 표시 — 컨트롤러가 결과(성공/실패+메시지)를 알아야 하므로 모델 콜백 대신 명시적 서비스 호출을 선택.
7. **Traccar API 자격증명**: Rails credentials(`credentials[:traccar][:api_base_url/:api_email/:api_password]`). HTTP 클라이언트는 표준 라이브러리 `Net::HTTP`(신규 gem 의존성 추가 안 함).

## 데이터 모델 변경

```ruby
# migration: add_traccar_geofence_id_to_stops
add_column :stops, :traccar_geofence_id, :integer

# migration: create_stop_visits
create_table :stop_visits do |t|
  t.references :stop, null: false, foreign_key: true
  t.references :trip, null: false, foreign_key: true
  t.string   :event_type, null: false   # "enter" | "exit"
  t.datetime :occurred_at, null: false
  t.timestamps
end
```

## Outbound: TraccarGeofenceSync 서비스

```ruby
# app/services/traccar_geofence_sync.rb
class TraccarGeofenceSync
  SIDE_METERS = 30

  Result = Struct.new(:success, :error, keyword_init: true) do
    def failure? = !success
  end

  def self.call(stop)   # 생성/수정
  def self.destroy(stop) # 삭제
end
```

- WKT `POLYGON(...)` 사각형 계산 → Traccar geofence 생성/수정 API 호출 → device(`bus.traccar_device_id`)에 permission 연결.
- 예외는 서비스 내부에서 잡아 `Result.failure(message)`로 변환, 로그(`Rails.logger.error`)도 남김.
- `route.bus`/`bus.traccar_device_id` 없으면 `Result.success`(스킵, 에러 아님)로 반환.

`Admin::StopsController`의 create/update/destroy에서 저장 성공 후 호출, 실패 시 `flash[:alert]`.

## Inbound: geofence 이벤트 수신

```ruby
# config/routes.rb — namespace :integrations 안에 추가
post "traccar/events", to: "traccar#events"
```

```ruby
# app/controllers/integrations/traccar_controller.rb 에 액션 추가
def events
  event = params[:event] || {}
  return head :ok unless %w[geofenceEnter geofenceExit].include?(event[:type])

  stop = Stop.find_by(traccar_geofence_id: event[:geofenceId])
  bus  = Bus.find_by(traccar_unique_id: params.dig(:device, :uniqueId))
  return head :ok if stop.nil? || bus.nil?

  trip = bus.trips.where(ended_at: nil).order(started_at: :desc).first
  return head :ok unless trip

  trip.stop_visits.create!(
    stop: stop,
    event_type: event[:type] == "geofenceEnter" ? "enter" : "exit",
    occurred_at: parse_time(event[:eventTime])
  )
  head :ok
end
```

- 알 수 없는 geofence/device/activate trip 없음 → 200 ack로 조용히 무시(position 수신과 동일 패턴, 재시도 폭주 방지).
- 운영 측: `traccar.xml`에 `event.forward.url` 별도 설정 필요(운영자 수동 작업, `docs/traccar-integration.md`에 추가 문서화).

## 테스트 관점

- `TraccarGeofenceSync`: WKT 계산 정확성, bus/device 없을 때 스킵 동작, API 실패 시 Result.failure 반환(Traccar API mock/stub).
- `Admin::StopsController`: 동기화 실패 시 flash 표시하면서도 Stop 저장은 성공하는지.
- `Integrations::TraccarController#events`: 인증 실패, 알 수 없는 geofence/device, 활성 trip 없음, 정상 enter/exit 각 케이스.
