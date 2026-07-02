class CreateStopVisits < ActiveRecord::Migration[8.1]
  def change
    create_table :stop_visits do |t|
      t.references :stop, null: false, foreign_key: true
      t.references :trip, null: false, foreign_key: true
      t.string :event_type, null: false
      t.datetime :occurred_at, null: false

      t.timestamps
    end
  end
end
