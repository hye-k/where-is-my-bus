class AddUniqueIndexToStopVisits < ActiveRecord::Migration[8.1]
  def change
    add_index :stop_visits, [ :trip_id, :stop_id, :event_type, :occurred_at ],
      unique: true, name: "index_stop_visits_on_trip_stop_event_occurred_at"
  end
end
