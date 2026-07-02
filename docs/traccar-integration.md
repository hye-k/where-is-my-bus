# Traccar 위치 추적 연동 설계

오픈소스 GPS 추적 서버 [Traccar](https://www.traccar.org/)로 버스 위치를 수집하고, 기존 시민 서비스의 도착정보(ETA·진행바)에 반영한다.

## 결정 사항 (MVP)

1. **운전자 단말**: 공식 **Traccar Client 앱**을 그대로 사용 — 커스텀 iOS 앱 미개발.
2. **실시간 방식**: 기존 **폴링 유지**(`arrival_polling_controller.js`, 5초). Solid Cable 도입은 보류.
3. **지도**: 시민 화면은 **진행바만 유지**. 별도 지도 없음.

## 데이터 흐름

```
운전자 폰 (Traccar Client, OsmAnd :5055)
   └─ GPS(id·lat·lon) ─▶ Traccar 서버 (Docker, API :8082)
                              ├─ 위치 포워딩(JSON POST) ─▶ Rails  POST /integrations/traccar/positions
                              │                                └─ Bus 매핑 → Trip → GpsLog 적재
                              │                                      └─ 기존 stops#arrival(폴링)이 읽어 시민 웹에 표시
                              └─ geofence 이벤트(JSON POST) ─▶ Rails  POST /integrations/traccar/events
                                                                   └─ Stop/Bus 매핑 → StopVisit 적재
```

## Rails 수신 측 (구현 완료 — Phase 1)

- **모델**: `buses.traccar_unique_id`(단말 식별자, unique) / `buses.traccar_device_id`(Traccar 내부 device id, 프로비저닝용).
- **엔드포인트**: `POST /integrations/traccar/positions` (`Integrations::TraccarController < ActionController::API`)
  - `X-Ingest-Token` 헤더로 인증(타이밍 안전 비교). 토큰 출처: `credentials[:traccar][:ingest_token]` → `ENV["TRACCAR_INGEST_TOKEN"]` → 개발 기본값 `dev-traccar-token`. 운영에서 미설정 시 **fail-closed**.
  - payload `device.uniqueId` → `Bus` 조회. 그 버스의 **열린 Trip**(없으면 생성)에 `GpsLog`(lat/lng/recorded_at) 적재.
  - 알 수 없는 단말·좌표 누락은 `200`(ack)로 무시 → 포워딩 재시도 폭주 방지.
- 기존 `Trip`/`GpsLog`/`stops#arrival` 로직을 그대로 재사용한다. (시드의 가짜 GPS가 진짜 위치로 대체될 뿐)

### Traccar 포워딩 설정 (`traccar.xml`)

```xml
<entry key='forward.enable'>true</entry>
<entry key='forward.url'>https://<오리진>/integrations/traccar/positions</entry>
<entry key='forward.json'>true</entry>
<entry key='forward.header'>X-Ingest-Token: <비밀토큰></entry>
```

## Geofence 동기화 (구현 완료 — Phase 1.5)

- **모델**: `stops.traccar_geofence_id`(Traccar geofence id) / 신규 `StopVisit`(stop_id, trip_id, event_type enter/exit, occurred_at).
- **Outbound**: `Admin::StopsController`가 Stop 저장/삭제 시 `TraccarGeofenceSync`를 호출해 Traccar에 사각형(변 30m) geofence를 생성/수정/삭제하고 `route.bus`의 device에 연결. `route.bus`가 없으면 조용히 스킵. API 실패 시 Stop 저장은 유지되고 admin에 flash 경고만 표시.
- **Inbound**: `POST /integrations/traccar/events` — 기존 `X-Ingest-Token` 인증 재사용. `event.type`이 `geofenceEnter`/`geofenceExit`일 때만 처리, `geofenceId`→`Stop`, `device.uniqueId`→`Bus` 매핑 후 그 버스의 **열린 Trip**(없으면 생성, `positions`와 동일)에 `StopVisit` 생성. 매핑 실패(알 수 없는 stop/device)는 200 ack로 무시.
- **운영 측 추가 설정**: `traccar.xml`에 `event.forward.url` 별도 추가 필요(`forward.url`과는 다른 엔드포인트 `/integrations/traccar/events`).

```xml
<entry key='event.forward.enable'>true</entry>
<entry key='event.forward.url'>https://<오리진>/integrations/traccar/events</entry>
<entry key='event.forward.json'>true</entry>
<entry key='event.forward.header'>X-Ingest-Token: <비밀토큰></entry>
```

- **Traccar API 자격증명**: geofence 생성/수정/삭제(outbound) 호출 시 Traccar 관리자 계정으로 인증. `credentials[:traccar][:api_base_url]` / `[:api_email]` / `[:api_password]`로 관리(`bin/rails credentials:edit`).

> 시민 화면 반영(도착정보 페이지에 방문 이력 표시)은 별도 단계로 로드맵에 남겨둠. Route-Bus 1:N 구조 전환도 별도 작업.

## 운영 측 (운영자가 수행 — 미구현/수동)

- **Traccar 서버**: Docker(`traccar/traccar`)로 기동, 데이터 볼륨 + `traccar.xml` 영속화. 포트 8082(API/WS), 5055(OsmAnd 수신).
- **차량 ↔ 단말 등록**: 각 버스에 추측 불가능한 `traccar_unique_id` 발급(예: `goseong-1-a8f3c2`). 운전자는 Traccar Client에 서버 주소 + 이 식별자 입력 후 "시작".
- **PIN 흐름**: 기존 `PinCode`는 운영자가 운전자에게 단말 식별자를 발급/승인하는 본인확인 용도로 유지.

## 보안

- 수신 엔드포인트: 공유 토큰 헤더 필수(+가능하면 Traccar 호스트 IP 제한·rate limit).
- `traccar_unique_id`는 추측 불가능해야 함 — OsmAnd는 id만 알면 위치 주입 가능하므로 스푸핑 방지의 핵심.
- Traccar 매니저 자격증명·ingest 토큰은 Rails credentials/ENV로 관리(커밋 금지).

## 단계별 로드맵

| 단계 | 내용 | 상태 |
|---|---|---|
| 0 | Traccar Docker 기동 + Traccar Client로 위치 수신 확인 | 운영 수동 |
| 1 | Rails 수신 엔드포인트 + 모델 컬럼 + 포워딩 → GpsLog 적재 | **완료** |
| 1.5 | Stop geofence 동기화(Traccar) + geofence 이벤트 수신 → StopVisit 적재 | **완료** |
| 2 | 차량 등록 시 Traccar 디바이스 자동 프로비저닝(REST API) + admin 단말 상태 표시 | 예정 |
| 3 | Trip 자동 종료(오프라인/타임아웃, Solid Queue) | 예정 |

> 폴링 유지·지도 미도입 결정에 따라, 실시간 Cable·지도 단계는 로드맵에서 제외.
