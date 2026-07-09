require "test_helper"

class Admin::AreasControllerTest < ActionDispatch::IntegrationTest
  setup do
    TraccarGeofenceSync.stub_credentials(
      base_url: "http://traccar.test",
      email: "admin@example.com",
      password: "secret"
    )
    sign_in_as(users(:operator))
  end

  test "destroy cleans up geofences for all cascade-deleted stops" do
    area = areas(:one)
    stop = stops(:one)
    stop.update!(traccar_geofence_id: 99)

    stub_request(:delete, "http://traccar.test/api/geofences/99").to_return(status: 204)

    delete admin_area_path(area)

    assert_requested(:delete, "http://traccar.test/api/geofences/99")
  end
end
