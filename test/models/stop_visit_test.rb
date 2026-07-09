require "test_helper"

class StopVisitTest < ActiveSupport::TestCase
  test "valid with stop, trip, event_type, occurred_at" do
    stop = stops(:one)
    trip = trips(:active)

    visit = StopVisit.new(stop: stop, trip: trip, event_type: "enter", occurred_at: Time.current)

    assert visit.valid?
  end

  test "invalid without event_type" do
    visit = StopVisit.new(stop: stops(:one), trip: trips(:active), occurred_at: Time.current)

    assert_not visit.valid?
    assert_includes visit.errors[:event_type], "can't be blank"
  end

  test "invalid with event_type outside enter/exit" do
    visit = StopVisit.new(stop: stops(:one), trip: trips(:active), event_type: "bogus", occurred_at: Time.current)

    assert_not visit.valid?
    assert_includes visit.errors[:event_type], "is not included in the list"
  end

  test "invalid without occurred_at" do
    visit = StopVisit.new(stop: stops(:one), trip: trips(:active), event_type: "enter")

    assert_not visit.valid?
    assert_includes visit.errors[:occurred_at], "can't be blank"
  end

  test "invalid when a StopVisit with the same trip, stop, event_type, and occurred_at already exists" do
    existing = StopVisit.create!(stop: stops(:one), trip: trips(:active), event_type: "enter", occurred_at: Time.current)
    dup = StopVisit.new(stop: existing.stop, trip: existing.trip, event_type: existing.event_type, occurred_at: existing.occurred_at)

    assert_not dup.valid?
    assert_includes dup.errors[:trip_id], "has already been taken"
  end
end
