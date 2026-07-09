# test/services/traccar_geofence_sync_test.rb
require "test_helper"

class TraccarGeofenceSyncTest < ActiveSupport::TestCase
  setup do
    TraccarGeofenceSync.stub_credentials(
      base_url: "http://traccar.test",
      email: "admin@example.com",
      password: "secret"
    )
  end

  test "rectangle_wkt builds a closed 4-point polygon around the center" do
    wkt = TraccarGeofenceSync.rectangle_wkt(lat: 35.0, lng: 128.0, side_meters: 30)

    assert_match(/\APOLYGON\(\(.+\)\)\z/, wkt)

    coords = wkt[/\(\((.+)\)\)/, 1].split(",").map { |pair| pair.strip.split(" ").map(&:to_f) }
    assert_equal 5, coords.size # 4 corners + closing point back to start
    assert_equal coords.first, coords.last

    lats = coords.map(&:first)
    lngs = coords.map(&:last)
    assert_in_delta 35.0, (lats.min + lats.max) / 2, 0.001
    assert_in_delta 128.0, (lngs.min + lngs.max) / 2, 0.001
  end

  test "call creates a new geofence and links it to the bus device when stop has no geofence yet" do
    stop = stops(:one) # route -> bus fixture 필요, traccar_geofence_id: nil
    bus  = stop.route.bus
    bus.update!(traccar_device_id: 42, traccar_unique_id: "dev-42")

    stub_request(:post, "http://traccar.test/api/geofences")
      .with(basic_auth: [ "admin@example.com", "secret" ])
      .to_return(status: 200, body: { id: 99 }.to_json, headers: { "Content-Type" => "application/json" })

    stub_request(:post, "http://traccar.test/api/permissions")
      .with(basic_auth: [ "admin@example.com", "secret" ], body: { deviceId: 42, geofenceId: 99 }.to_json)
      .to_return(status: 204)

    result = TraccarGeofenceSync.call(stop)

    assert result.success
    assert_equal 99, stop.reload.traccar_geofence_id
  end

  test "call skips silently when route has no bus assigned" do
    stop = stops(:one)
    stop.route.update!(bus: nil)

    result = TraccarGeofenceSync.call(stop)

    assert result.success
    assert_nil stop.reload.traccar_geofence_id
  end

  test "call returns failure result when Traccar API errors, without raising" do
    stop = stops(:one)
    bus  = stop.route.bus
    bus.update!(traccar_device_id: 42)

    stub_request(:post, "http://traccar.test/api/geofences").to_timeout

    result = TraccarGeofenceSync.call(stop)

    assert result.failure?
    assert_match(/geofence/i, result.error)
  end

  test "call re-raises unexpected programming errors instead of swallowing them into a Result" do
    stop = stops(:one)
    bus  = stop.route.bus
    bus.update!(traccar_device_id: 42)

    # Minitest 6 dropped Minitest::Mock#stub into a separate gem not present in this
    # environment, so we force the same failure mode (an unexpected NoMethodError deep
    # inside `call`) via a temporary singleton method override instead.
    original_method = TraccarGeofenceSync.method(:rectangle_wkt)
    TraccarGeofenceSync.define_singleton_method(:rectangle_wkt) do |*|
      raise NoMethodError, "boom"
    end

    begin
      assert_raises(NoMethodError) do
        TraccarGeofenceSync.call(stop)
      end
    ensure
      TraccarGeofenceSync.define_singleton_method(:rectangle_wkt, original_method)
    end
  end

  test "destroy removes geofence from Traccar when stop has traccar_geofence_id" do
    stop = stops(:one)
    stop.update!(traccar_geofence_id: 99)

    stub_request(:delete, "http://traccar.test/api/geofences/99")
      .with(basic_auth: [ "admin@example.com", "secret" ])
      .to_return(status: 204)

    result = TraccarGeofenceSync.destroy(stop)

    assert result.success
  end
end
