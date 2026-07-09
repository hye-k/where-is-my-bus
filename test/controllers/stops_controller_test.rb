require "test_helper"

class StopsControllerTest < ActionDispatch::IntegrationTest
  test "arrival prefers the most recent StopVisit over GPS nearest-stop when both are present" do
    trip = trips(:active)
    # GPS 좌표는 stop one(sequence 1) 근처를 가리키지만
    GpsLog.create!(trip: trip, lat: stops(:one).lat, lng: stops(:one).lng, recorded_at: Time.current)
    # StopVisit은 stop two(sequence 2)를 가장 최근에 가리킴 → StopVisit이 우선해야 함
    StopVisit.create!(stop: stops(:two), trip: trip, event_type: "enter", occurred_at: Time.current)

    get stop_arrival_json_path(region_slug: regions(:one).slug, stop_id: stops(:three).id)

    json = JSON.parse(response.body)
    # bus_stop이 GPS 기준(one, sequence 1)이 아니라 StopVisit 기준(two, sequence 2)으로 계산되어야 함
    # target(three, seq 3) 기준 ahead = [three] 1개 → stops_away 1
    assert_equal 1, json["stops_away"]
    # bar_pct = 노선 내 위치. 정류장 3개(seq1/2/3) 중 seq2 → index1 → 1/2*100 = 50
    assert_equal 50, json["bar_pct"]
  end

  test "arrival bar_pct maps the bus stop to its position along the whole route" do
    trip = trips(:active)
    # 노선 첫 정류장(seq1)에 버스 → index0 → 0%
    StopVisit.create!(stop: stops(:one), trip: trip, event_type: "enter", occurred_at: Time.current)

    get stop_arrival_json_path(region_slug: regions(:one).slug, stop_id: stops(:three).id)

    assert_equal 0, JSON.parse(response.body)["bar_pct"]
  end

  test "arrival falls back to GPS nearest-stop when no StopVisit exists" do
    trip = trips(:active)
    GpsLog.create!(trip: trip, lat: stops(:one).lat, lng: stops(:one).lng, recorded_at: Time.current)

    get stop_arrival_json_path(region_slug: regions(:one).slug, stop_id: stops(:three).id)

    json = JSON.parse(response.body)
    # bus_stop = one(seq 1) → target(three, seq 3) 기준 ahead = [two, three] 2개
    assert_equal 2, json["stops_away"]
  end

  test "arrival ignores a StopVisit for a stop outside the target route" do
    other_route = Route.create!(area: areas(:one), name: "다른노선")
    other_stop = Stop.create!(route: other_route, name: "다른노선정류장", sequence: 1, lat: 36.0, lng: 129.0)

    trip = trips(:active)
    GpsLog.create!(trip: trip, lat: stops(:one).lat, lng: stops(:one).lng, recorded_at: Time.current)
    StopVisit.create!(stop: other_stop, trip: trip, event_type: "enter", occurred_at: Time.current)

    get stop_arrival_json_path(region_slug: regions(:one).slug, stop_id: stops(:three).id)

    json = JSON.parse(response.body)
    # other_route의 StopVisit은 무시되고 GPS fallback(one, seq 1) 사용 → ahead = [two, three] 2개
    assert_equal 2, json["stops_away"]
  end

  test "arrival reports arrival (stops_away 0) when StopVisit is at/past target, even without GPS" do
    trip = trips(:active)
    # GPS 없이 StopVisit만 존재. StopVisit이 target(three, seq 3) 자체를 가리킴.
    # 점 스냅 방식은 GPS 보간이 필요 없으므로 도착으로 표시(과거엔 no_data 였음)
    StopVisit.create!(stop: stops(:three), trip: trip, event_type: "enter", occurred_at: Time.current)

    get stop_arrival_json_path(region_slug: regions(:one).slug, stop_id: stops(:three).id)

    json = JSON.parse(response.body)
    assert_nil json["status"]
    assert_equal 0, json["stops_away"]
    # seq3 → index2 → 2/2*100 = 100 (노선 끝)
    assert_equal 100, json["bar_pct"]
  end

  test "detail marks the StopVisit-matched stop as current_bus, not the GPS nearest stop" do
    trip = trips(:active)
    GpsLog.create!(trip: trip, lat: stops(:one).lat, lng: stops(:one).lng, recorded_at: Time.current)
    StopVisit.create!(stop: stops(:two), trip: trip, event_type: "enter", occurred_at: Time.current)

    get stop_detail_path(region_slug: regions(:one).slug, stop_id: stops(:three).id)

    current = @controller.instance_variable_get(:@route_stops).find { |s| s[:current_bus] }
    assert_equal "배둔", current[:name]
  end
end
