# app/services/traccar_geofence_sync.rb
require "net/http"
require "json"

class TraccarGeofenceSync
  SIDE_METERS = 30
  METERS_PER_LAT_DEGREE = 111_320.0

  Result = Struct.new(:success, :error, keyword_init: true) do
    def failure? = !success
  end

  class << self
    # lat/lng를 중심으로 한 변 side_meters 크기의 정사각형을 WKT POLYGON 문자열로 반환.
    # 위도 1도 ≈ 111.32km 고정 근사 + 경도는 cos(lat) 보정. 30m 규모에서는 이 근사의 오차가 무시 가능한 수준.
    def rectangle_wkt(lat:, lng:, side_meters: SIDE_METERS)
      half = side_meters / 2.0
      dlat = half / METERS_PER_LAT_DEGREE
      dlng = half / (METERS_PER_LAT_DEGREE * Math.cos(lat * Math::PI / 180))

      corners = [
        [ lat - dlat, lng - dlng ],
        [ lat - dlat, lng + dlng ],
        [ lat + dlat, lng + dlng ],
        [ lat + dlat, lng - dlng ],
        [ lat - dlat, lng - dlng ]
      ]

      "POLYGON((#{corners.map { |c| c.join(' ') }.join(', ')}))"
    end

    # stop 생성/수정 시 호출. bus/device 매핑이 없으면 조용히 스킵(성공 취급).
    def call(stop)
      return Result.new(success: true) unless stop.coordinates?

      bus = stop.route&.bus
      return Result.new(success: true) unless bus&.traccar_device_id

      wkt = rectangle_wkt(lat: stop.lat.to_f, lng: stop.lng.to_f)
      name = "stop-#{stop.id}"

      if stop.traccar_geofence_id.present?
        update_geofence(stop.traccar_geofence_id, name, wkt)
      else
        geofence_id = create_geofence(name, wkt)
        stop.update!(traccar_geofence_id: geofence_id)
      end

      link_device(bus.traccar_device_id, stop.traccar_geofence_id)
      Result.new(success: true)
    rescue => e
      Rails.logger.error("[TraccarGeofenceSync] #{stop.id}: #{e.class} #{e.message}")
      Result.new(success: false, error: "geofence 동기화 실패: #{e.message}")
    end

    def destroy(stop)
      return Result.new(success: true) unless stop.traccar_geofence_id

      request(:delete, "/api/geofences/#{stop.traccar_geofence_id}")
      Result.new(success: true)
    rescue => e
      Rails.logger.error("[TraccarGeofenceSync] destroy #{stop.id}: #{e.class} #{e.message}")
      Result.new(success: false, error: "geofence 삭제 실패: #{e.message}")
    end

    # 테스트용: credentials 대신 명시적으로 접속 정보를 주입
    def stub_credentials(base_url:, email:, password:)
      @stubbed = { base_url: base_url, email: email, password: password }
    end

    private

    def create_geofence(name, wkt)
      res = request(:post, "/api/geofences", { name: name, area: wkt })
      JSON.parse(res.body)["id"]
    end

    def update_geofence(id, name, wkt)
      request(:put, "/api/geofences/#{id}", { id: id, name: name, area: wkt })
    end

    def link_device(device_id, geofence_id)
      request(:post, "/api/permissions", { deviceId: device_id, geofenceId: geofence_id })
    end

    def request(method, path, body = nil)
      creds = @stubbed || {
        base_url: Rails.application.credentials.dig(:traccar, :api_base_url),
        email: Rails.application.credentials.dig(:traccar, :api_email),
        password: Rails.application.credentials.dig(:traccar, :api_password)
      }

      uri = URI.join(creds[:base_url], path)
      klass = { get: Net::HTTP::Get, post: Net::HTTP::Post, put: Net::HTTP::Put, delete: Net::HTTP::Delete }.fetch(method)
      req = klass.new(uri)
      req.basic_auth(creds[:email], creds[:password])
      if body
        req["Content-Type"] = "application/json"
        req.body = body.to_json
      end

      res = Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(req) }
      raise "Traccar API #{method} #{path} → #{res.code}" unless res.is_a?(Net::HTTPSuccess)
      res
    end
  end
end
