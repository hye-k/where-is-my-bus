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
end
