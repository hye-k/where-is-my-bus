require "test_helper"

class Admin::StopsControllerTest < ActionDispatch::IntegrationTest
  setup do
    TraccarGeofenceSync.stub_credentials(
      base_url: "http://traccar.test",
      email: "admin@example.com",
      password: "secret"
    )
    sign_in_as(users(:operator))
    stops(:one).route.bus.update!(traccar_device_id: 42)
  end

  test "create shows alert flash when geofence sync fails, but still saves the stop" do
    stub_request(:post, /traccar/).to_timeout

    assert_difference("Stop.count", 1) do
      post admin_stops_path, params: { stop: {
        route_id: routes(:one).id, name: "새 정류장", sequence: 2, lat: 35.01, lng: 128.01
      } }
    end

    assert_redirected_to admin_stops_path(route_id: routes(:one).id)
    assert_match(/geofence/i, flash[:alert])
  end

  test "create does not set alert flash when geofence sync succeeds" do
    stub_request(:post, "http://traccar.test/api/geofences")
      .to_return(status: 200, body: { id: 5 }.to_json, headers: { "Content-Type" => "application/json" })
    stub_request(:post, "http://traccar.test/api/permissions").to_return(status: 204)

    post admin_stops_path, params: { stop: {
      route_id: routes(:one).id, name: "새 정류장", sequence: 2, lat: 35.01, lng: 128.01
    } }

    assert_nil flash[:alert]
  end

  test "destroy shows alert flash when geofence sync fails, but still deletes the stop" do
    stop = stops(:one)
    stop.update!(traccar_geofence_id: 99)
    stub_request(:delete, "http://traccar.test/api/geofences/99").to_timeout

    assert_difference("Stop.count", -1) do
      delete admin_stop_path(stop)
    end

    assert_redirected_to admin_stops_path(route_id: routes(:one).id)
    assert_match(/geofence/i, flash[:alert])
  end

  test "sync_geofence action retries the geofence sync and shows success notice" do
    stop = stops(:one)
    stub_request(:post, "http://traccar.test/api/geofences")
      .to_return(status: 200, body: { id: 5 }.to_json, headers: { "Content-Type" => "application/json" })
    stub_request(:post, "http://traccar.test/api/permissions").to_return(status: 204)

    post sync_geofence_admin_stop_path(stop)

    assert_redirected_to admin_stop_path(stop)
    assert_equal "geofence 동기화에 성공했습니다.", flash[:notice]
  end

  test "sync_geofence action shows alert flash when retry fails" do
    stop = stops(:one)
    stub_request(:post, "http://traccar.test/api/geofences").to_timeout

    post sync_geofence_admin_stop_path(stop)

    assert_redirected_to admin_stop_path(stop)
    assert_match(/geofence/i, flash[:alert])
  end

  test "mock_visit attaches an enter StopVisit to the active trip without creating a new trip" do
    stop = stops(:one)

    assert_difference("StopVisit.count", 1) do
      assert_no_difference("Trip.count") do
        post mock_visit_admin_stop_path(stop)
      end
    end

    visit = StopVisit.order(:id).last
    assert_equal stop.id, visit.stop_id
    assert_equal trips(:active).id, visit.trip_id
    assert_equal "enter", visit.event_type
    assert_redirected_to admin_stop_path(stop)
    assert_match(/mock/i, flash[:notice])
  end

  test "mock_visit creates a new trip when the bus has no active trip" do
    trips(:active).update!(ended_at: Time.current)
    stop = stops(:one)

    assert_difference([ "StopVisit.count", "Trip.count" ], 1) do
      post mock_visit_admin_stop_path(stop)
    end
  end

  test "mock_visit redirects back to the referring page (e.g. the stops list)" do
    stop = stops(:one)
    list_url = admin_stops_path(route_id: routes(:one).id)

    post mock_visit_admin_stop_path(stop), headers: { "HTTP_REFERER" => list_url }

    assert_redirected_to list_url
  end

  test "mock_visit shows alert and creates nothing when the route has no bus" do
    routes(:one).update!(bus: nil)
    stop = stops(:one)

    assert_no_difference("StopVisit.count") do
      post mock_visit_admin_stop_path(stop)
    end

    assert_redirected_to admin_stop_path(stop)
    assert flash[:alert].present?
  end
end
