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
end
