class StopVisit < ApplicationRecord
  belongs_to :stop
  belongs_to :trip

  validates :event_type, presence: true, inclusion: { in: %w[enter exit] }
  validates :occurred_at, presence: true
end
