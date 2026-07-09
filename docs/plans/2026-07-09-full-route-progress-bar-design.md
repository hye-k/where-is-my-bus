# 시민 진행바를 노선 전체 정류장으로 (점 수 = 정류장 수) 설계

작성일: 2026-07-09
브랜치: `feature/traccar-geofence-events`

## 배경 / 문제

기존 진행바는 "목적지 직전 3개 정류장(-3/-2/-1/현재)"만 보여주는 **상대 접근바**였다.
점이 4개로 고정(0%/15%/30% + 목적지 핀 100%)이라, 8개 정류장 노선이 4점으로 압축돼
정류장 수와 점 수가 불일치했다. `arrival`의 `bar_pct`도 이 4점 스케일(3/15/30 + GPS 보간)에 묶여 있었다.

## 목표

노선의 **전체 정류장 N개를 점 N개로** 균등 표시하고, 버스 마커를 현재 정류장 점에 스냅한다.

## 결정 사항

- **점 배치**: i번째 정류장(0-based) → `left = i/(N-1)×100%`. 지금 보고 있는 정류장은 목적지 핀으로 강조.
- **버스 위치 정밀도**: **정류장 점에 스냅**(discrete). StopVisit(geofence)이 정류장 단위 신호라 일관되고 단순. 점→점 이동은 CSS transition 으로 애니메이션. (GPS 점간 보간은 채택 안 함.)
- **`bar_pct` 재정의**: 버스 현재 정류장의 노선 내 위치 = `bus_index/(N-1)×100`. 모든 경우 동일 공식.
- **GPS 보간 분기 제거**: 기존 "목적지 도달 시 GPS로 progress 보간, GPS 없으면 no_data" 로직 삭제.
  → 부수 효과: **StopVisit만 있고 GPS가 없어도** 도착/위치 표시 가능(기존 알려진 제약 해소).

## 변경 범위

1. `StopsController#show`: 노선 전체 정류장 `@route_stops = @stop.route.stops.order(:sequence)` 전달.
2. `StopsController#arrival`: `bar_pct`를 노선 내 위치로 산출, GPS 보간 분기 삭제.
   - `bus_stop.sequence >= target.sequence` → 도착/지나감(`stops_away 0, eta 0`)
   - 그 외 → 기존대로 `ahead` 기반 `stops_away`/`eta`
   - `bar_pct = N>1 ? round(bus_index/(N-1)*100) : 100`
3. `StopsController#debug_bus`: dev 시뮬레이터도 같은 스케일로. `bar_pct = ((seq-1)+pct/100)/(N-1)*100`.
4. `stops/show.html.erb`: 고정 점 3개 → 정류장 N개 동적 렌더. 목적지 핀을 보고 있는 정류장 점 위치에.
   0%/100% 마커 클리핑 방지용 좌우 패딩(px-4) 트랙.
5. `arrival_polling_controller.js`: 구 3/15/30 fallback 제거(`bar_pct`가 항상 서버에서 옴).

## 테스트 영향

- `stops_controller_test`
  - "StopVisit이 target(seq3)이고 GPS 없음" → 기존 `no_data` 기대를 **`stops_away 0`(도착)** 로 갱신.
  - `bar_pct` 값 검증 추가: 3개 정류장 fixture 기준 seq1→0, seq2→50, seq3→100.

## 범위 밖

- 정류장이 아주 많은 노선(예: 20+)에서의 점 밀집 처리 — MVP 노선 규모에선 불필요.
- GPS 기반 점간 보간(스무딩) — 채택 안 함(추후 개선 여지).
