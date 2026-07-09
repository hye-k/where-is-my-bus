require "test_helper"

class Integrations::TraccarControllerTest < ActionDispatch::IntegrationTest
  setup do
    @stop = stops(:one)
    @stop.update!(traccar_geofence_id: 99)
    @bus = @stop.route.bus
    @bus.update!(traccar_unique_id: "dev-42")
    # trips(:active) fixture also belongs to @bus and stays active by default;
    # end it here so it doesn't interfere with "no active trip" / "most recent trip" assertions below.
    trips(:active).update!(ended_at: Time.current)
    @trip = @bus.trips.create!(started_at: 1.hour.ago)
  end

  test "rejects request without valid token" do
    post integrations_traccar_events_path, params: geofence_event_payload, as: :json

    assert_response :unauthorized
  end

  test "creates a StopVisit on geofenceEnter for a known geofence and device with an active trip" do
    assert_difference("StopVisit.count", 1) do
      post integrations_traccar_events_path,
        params: geofence_event_payload,
        headers: { "X-Ingest-Token" => "dev-traccar-token" },
        as: :json
    end

    visit = StopVisit.last
    assert_equal @stop, visit.stop
    assert_equal @trip, visit.trip
    assert_equal "enter", visit.event_type
  end

  test "acks ok and creates nothing when geofence is unknown" do
    payload = geofence_event_payload
    payload[:event][:geofenceId] = 999999

    assert_no_difference("StopVisit.count") do
      post integrations_traccar_events_path,
        params: payload,
        headers: { "X-Ingest-Token" => "dev-traccar-token" },
        as: :json
    end

    assert_response :ok
  end

  test "auto-creates a trip and creates a StopVisit when no active trip exists yet" do
    @trip.update!(ended_at: Time.current)

    assert_difference("StopVisit.count", 1) do
      assert_difference("Trip.count", 1) do
        post integrations_traccar_events_path,
          params: geofence_event_payload,
          headers: { "X-Ingest-Token" => "dev-traccar-token" },
          as: :json
      end
    end

    assert_response :ok
    visit = StopVisit.last
    assert_equal @stop, visit.stop
    assert visit.trip.active?
  end

  test "does not create a duplicate StopVisit when the same event is retried" do
    payload = geofence_event_payload

    post integrations_traccar_events_path,
      params: payload,
      headers: { "X-Ingest-Token" => "dev-traccar-token" },
      as: :json

    assert_no_difference("StopVisit.count") do
      post integrations_traccar_events_path,
        params: payload,
        headers: { "X-Ingest-Token" => "dev-traccar-token" },
        as: :json
    end

    assert_response :ok
  end

  private

  def geofence_event_payload
    {
      event: { type: "geofenceEnter", geofenceId: 99, eventTime: Time.current.iso8601 },
      device: { uniqueId: "dev-42" },
      position: { latitude: 35.0, longitude: 128.0 }
    }
  end
end
