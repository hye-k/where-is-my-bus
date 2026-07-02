class AddIndexToStopsTraccarGeofenceId < ActiveRecord::Migration[8.1]
  def change
    add_index :stops, :traccar_geofence_id
  end
end
