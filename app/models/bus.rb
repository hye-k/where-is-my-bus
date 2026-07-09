class Bus < ApplicationRecord
  belongs_to :area
  has_many :routes,    dependent: :destroy
  has_many :trips,     dependent: :destroy
  has_many :pin_codes, dependent: :destroy

  enum :status, { active: "active", inactive: "inactive", deleted: "deleted" }

  validates :license_plate, presence: true, uniqueness: { scope: :area_id }
  validates :pin,           presence: true, format: { with: /\A\d{4,6}\z/, message: "은 4~6자리 숫자여야 합니다" }
  validates :traccar_unique_id, uniqueness: true, allow_nil: true

  default_scope { order(:license_plate) }

  def region
    area.region
  end

  def display_number
    return license_plate unless bus_number.present?
    I18n.locale == :ko ? bus_number : bus_number.gsub("번", "").strip
  end

  # 운행 중(ended_at IS NULL)인 trip을 반환하거나, 없으면 새로 시작한다.
  # GPS/geofence 이벤트 수신과 admin mock 발생 모두 "신호가 오면 trip은 있어야 한다"는 같은 규칙을 따른다.
  def find_or_create_active_trip!
    trips.where(ended_at: nil).order(started_at: :desc).first || trips.create!(started_at: Time.current)
  end
end
