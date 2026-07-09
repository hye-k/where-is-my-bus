# GPS/Geofence 우선순위 전환 설계

## 배경

`feature/traccar-geofence-events` 브랜치(`docs/plans/2026-07-02-stop-geofence-events-design.md`)에서 geofence 이벤트를 `StopVisit`으로 저장하는 기능을 이미 구현했지만, 시민 화면의 도착정보 계산(`StopsController`)은 여전히 GPS 좌표 최근접 계산(`nearest_stop`)만으로 "버스가 지금 어느 정류장 근처인가"를 추정하고 `StopVisit`을 전혀 참조하지 않는다.

MVP의 목표는 "내 정류장에 버스가 언제 오나"이지 "버스의 실시간 좌표"가 아니다. geofence event는 GPS 좌표 오차·폴링 주기에 흔들리지 않는, 더 신뢰되는 신호이므로 이를 1차 신호로, GPS를 보조/fallback 신호로 우선순위를 바꾼다.

이 설계는 사전 설계 차원의 개선이며, 실제 GPS/geofence 운영 데이터(오차 사례, 유실 빈도 등)는 아직 없는 상태에서 진행한다. 그래서 데이터 없이는 값을 정할 수 없는 요소(신선도 임계값 등)는 이번 범위에서 의도적으로 제외한다.

## 범위

- **바꾸는 것**: `bus_stop`("버스가 지금 어느 정류장 근처인가") 판정 로직만.
- **바꾸지 않는 것**: `progress`/`bar_pct` 등 구간 내 보간 계산은 기존 GPS 좌표 기반 그대로 유지.
- **대상 액션**: `StopsController#arrival`, `#detail` — 둘 다 현재 `active_trip_with_gps` + `nearest_stop` 조합을 쓰므로 공통 헬퍼 교체로 반영.
- **범위 밖 (의도적으로 미룸)**:
  - `#debug_bus`는 대상에서 제외 — 이 액션은 위치를 "판정"하는 게 아니라 `seq`/`pct` 파라미터로 GPS 좌표를 강제로 조작해 시뮬레이션하는 개발용 도구. `current_bus_stop`을 적용하면 같은 trip에 StopVisit이 남아있을 때 개발자가 지정한 `seq`를 무시하고 StopVisit 기준 정류장을 돌려줘서, 오히려 디버그 도구로서의 목적(임의 위치 강제 재현)이 깨짐.
  - enter/exit 상태머신 추적("정차 중" vs "이미 지나감" 구분) — 현재 `bus_stop`의 소비처(뱃지 표시, 구간 계산 기준점)가 이 구분을 요구하지 않고, exit 이벤트 유실 시 "영원히 그 정류장에 머무는 중"으로 착시되는 새 실패 모드를 만들기 때문에 채택하지 않음.
  - StopVisit 신선도(오래된 이벤트 무시) 임계값 — 실측 데이터 없이 임계값을 정할 근거가 없고 MVP 범위를 넘어섬. StopVisit이 있으면 얼마나 오래됐든 그대로 신뢰한다.

## 결정 사항

1. **판정 방식**: 활성 trip 범위 내에서 가장 최근 StopVisit 1건만 보고 판단(enter/exit 구분 없이). "최근 StopVisit이 가리키는 stop = 현재 위치"로 취급.
2. **조회 범위**: `trip.stop_visits.where(stop: all_stops)` — `active_trip_with_gps`가 이미 찾아둔 활성 trip과 동일한 범위로 한정. `GpsLog` 조회와 동일한 스코프 규칙이라 일관적이고, 다른 route/지난 운행의 StopVisit이 섞이는 것을 막는다.
3. **Fallback 조건**: 해당 trip·route 범위 내 StopVisit이 하나도 없을 때만 기존 `nearest_stop(GPS)`로 fallback. StopVisit이 있으면 신선도와 무관하게 무조건 사용.
4. **StopVisit이 가리키는 stop이 route 밖인 경우**: 별도 처리 불필요 — `where(stop: all_stops)` 조건 자체가 걸러냄.
5. **StopVisit도 GPS도 없는 경우**: 기존과 동일하게 `nearest_stop`이 nil을 반환하고, 기존 "no_data" 분기가 그대로 처리.

## 구현 형태

`active_trip_with_gps` + `nearest_stop` 호출부를 새 헬퍼로 교체:

```ruby
def current_bus_stop(trip, all_stops, latest_gps)
  visit_stop = trip.stop_visits.where(stop: all_stops).order(occurred_at: :desc).first&.stop
  visit_stop || nearest_stop(all_stops, latest_gps)
end
```

`nearest_stop`은 그대로 두고 fallback 용도로만 재사용. `arrival`/`detail`/`debug_bus` 세 곳에서 `bus_stop = nearest_stop(...)` 호출을 `bus_stop = current_bus_stop(trip, all_stops, latest_gps)`로 교체.

## 테스트 관점

- StopVisit이 있을 때 그걸 우선 사용하는지 (GPS가 다른 정류장을 가리켜도 StopVisit이 이김)
- StopVisit이 없을 때 기존 GPS fallback이 그대로 동작하는지
- StopVisit이 다른 route의 stop을 가리키는 경우 무시되는지 (현재 route 범위 밖)
- StopVisit도 GPS도 없을 때 기존 "no_data" 처리가 유지되는지
- `arrival`/`detail`/`debug_bus` 세 액션 모두에서 일관되게 동작하는지

## 참고

- 이번 설계가 다루는 `StopVisit`/geofence 이벤트 수신 자체의 설계는 `docs/plans/2026-07-02-stop-geofence-events-design.md` 참고.
- `.claude/HANDOFF.md`에 이 작업 착수 전 남겨둔 다음 우선순위 항목(운영 credentials 설정, Route-Bus 1:N 전환, 시민 화면에 StopVisit 반영)도 함께 참고.
