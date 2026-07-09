class StopsController < ApplicationController
  allow_unauthenticated_access
  before_action :no_turbo_cache, only: %i[show detail]

  def show
    @stop   = Stop.find_by(id: params[:stop_id])
    @bus    = @stop&.route&.bus
    @region = @bus&.region
    @area   = @bus&.area
    token = session[:like_token] ||= SecureRandom.hex(16)
    @likes_count      = @stop ? StopLike.where(stop_id: @stop.id).count : 0
    @already_liked    = @stop ? StopLike.where(stop_id: @stop.id, session_token: token)
                                        .where("created_at > ?", 1.hour.ago).exists? : false
    # 진행바를 노선 전체 정류장 점으로 렌더하기 위해 순서대로 로드 + 각 점의 노선 내 위치(%)를 미리 계산
    all_route_stops = @stop&.route ? @stop.route.stops.order(:sequence).to_a : []
    @route_stops = all_route_stops.each_with_index.map { |s, i| [ s, position_pct(index: i, total: all_route_stops.size) ] }
    load_selector_regions
  end

  def detail
    @stop = Stop.find_by(id: params[:stop_id])
    return head :not_found unless @stop

    @bus    = @stop.route&.bus
    @region = @bus&.region
    @area   = @bus&.area
    return render json: { error: "data error" }, status: :unprocessable_entity if @bus.nil? || @region.nil?

    @likes_count = StopLike.where(stop_id: @stop.id).count
    load_selector_regions

    all_stops = @stop.route.stops.order(:sequence).to_a

    trip, latest_gps = active_trip_with_gps(@bus)
    bus_stop = trip ? current_bus_stop(trip, all_stops, latest_gps) : nil

    @route_stops = all_stops.map do |s|
      { seq: s.sequence, name: s.display_name,
        current_bus: bus_stop&.id == s.id,
        here: @stop.id == s.id }
    end
  end

  def arrival
    target_stop = Stop.find_by(id: params[:stop_id])
    return render json: { status: "no_data", eta_minutes: nil, stops_away: nil } unless target_stop

    bus = target_stop.route&.bus
    return render json: { status: "no_data", eta_minutes: nil, stops_away: nil } unless bus

    trip, latest_gps = active_trip_with_gps(bus)
    return render json: { eta_minutes: nil, stops_away: nil, bus_number: bus.bus_number, status: "no_trip" } unless trip

    all_stops = target_stop.route.stops.order(:sequence).to_a
    bus_stop  = current_bus_stop(trip, all_stops, latest_gps)
    return render json: { status: "no_data", eta_minutes: nil, stops_away: nil, bus_number: bus.bus_number } unless bus_stop

    # 버스 마커는 노선 전체 정류장 점에 스냅한다 — 버스 정류장의 노선 내 위치(0~100%)
    bar_pct = position_pct(index: all_stops.index { |s| s.id == bus_stop.id } || 0, total: all_stops.size)

    if bus_stop.sequence >= target_stop.sequence
      # 목적지에 도착했거나 이미 지나감
      return render json: {
        eta_minutes: 0,
        stops_away:  0,
        bus_number:  bus.bus_number,
        bar_pct:     bar_pct
      }
    end

    ahead = all_stops.select { |s| s.sequence > bus_stop.sequence && s.sequence <= target_stop.sequence }
    total_seconds = ahead.sum { |s| s.avg_travel_seconds.to_i }

    render json: {
      eta_minutes: (total_seconds / 60.0).ceil,
      stops_away:  ahead.size,
      bus_number:  bus.bus_number,
      bar_pct:     bar_pct
    }
  end

  def debug_bus
    return render json: { error: "not found" }, status: :not_found unless Rails.env.development?

    target_stop = Stop.find_by(id: params[:stop_id])
    return render json: { error: "stop not found" }, status: :not_found unless target_stop

    seq = params[:seq].to_i
    pct = params[:pct].to_f.clamp(0.0, 100.0)
    return render json: { error: "invalid seq" }, status: :bad_request if seq <= 0

    route     = target_stop.route
    all_stops = route.stops.order(:sequence).to_a

    bus_stop    = all_stops.find { |s| s.sequence == seq }
    return render json: { error: "sequence not found" }, status: :not_found unless bus_stop

    # 목표 정류장: 현재 페이지의 정류장 (params[:stop_id])
    debug_target = target_stop

    trip = route.bus.trips.where(ended_at: nil).order(started_at: :desc).first
    return render json: { error: "no active trip" }, status: :unprocessable_entity unless trip

    # pct: 0 = 정류장 위치, 0~100 = 다음 정류장 방향 보간 (상단에서 이미 clamp 처리됨)

    # GPS 위치 계산 (보간 포함)
    gps_lat, gps_lng = if pct > 0
      next_stop = all_stops.find { |s| s.sequence == seq + 1 }
      next_stop ? [
        bus_stop.lat.to_f + (next_stop.lat.to_f - bus_stop.lat.to_f) * pct / 100,
        bus_stop.lng.to_f + (next_stop.lng.to_f - bus_stop.lng.to_f) * pct / 100
      ] : [ bus_stop.lat.to_f, bus_stop.lng.to_f ]
    else
      [ bus_stop.lat.to_f, bus_stop.lng.to_f ]
    end

    gps = trip.gps_logs.order(recorded_at: :desc).first
    if gps
      gps.update!(lat: gps_lat, lng: gps_lng, recorded_at: Time.current)
    else
      GpsLog.create!(trip: trip, lat: gps_lat, lng: gps_lng, recorded_at: Time.current)
    end

    # 진행바 위치: 노선 내 정류장 점 위치 + 다음 점까지 pct 보간 (arrival 의 점 배치와 정렬)
    idx = all_stops.index { |s| s.id == bus_stop.id } || 0
    bar_pct = position_pct(index: idx, total: all_stops.size, sub_pct: pct)

    if bus_stop.sequence >= debug_target.sequence
      return render json: {
        bus_stop: bus_stop.name, target_stop: debug_target.name,
        bus_lat: gps_lat, bus_lng: gps_lng,
        eta_minutes: 0, stops_away: 0,
        bar_pct: bar_pct, message: "현위치 도착"
      }
    end

    ahead         = all_stops.select { |s| s.sequence > bus_stop.sequence && s.sequence <= debug_target.sequence }
    total_seconds = if pct > 0 && ahead.size == 1
      (ahead.first.avg_travel_seconds.to_i * (1.0 - pct / 100.0)).ceil
    else
      ahead.sum { |s| s.avg_travel_seconds.to_i }
    end

    render json: {
      bus_stop:    bus_stop.name,
      target_stop: debug_target.name,
      bus_lat:     gps_lat,
      bus_lng:     gps_lng,
      eta_minutes: (total_seconds / 60.0).ceil,
      stops_away:  ahead.size,
      bar_pct:     bar_pct,
      via:         ahead.map(&:name)
    }
  end

  def like
    stop = Stop.find_by(id: params[:stop_id])
    return render json: { error: "not found" }, status: :not_found unless stop

    token  = session[:like_token] ||= SecureRandom.hex(16)
    bus_id = stop.route&.bus_id
    # NOTE: session 기반 중복 방지는 쿠키 삭제/시크릿 모드로 우회 가능. MVP 단계 의도된 트레이드오프.
    return render json: { error: "data error" }, status: :unprocessable_entity unless bus_id

    already_liked = StopLike.where(stop_id: stop.id, session_token: token)
                             .where("created_at > ?", 1.hour.ago).exists?

    unless already_liked
      begin
        StopLike.create!(stop_id: stop.id, bus_id: bus_id, session_token: token)
      rescue ActiveRecord::RecordNotUnique
        # 동시 요청으로 인한 중복 — 무시하고 현재 카운트 반환
      end
    end

    render json: {
      count: StopLike.where(stop_id: stop.id).count,
      already_liked: true
    }
  end

  private

  # 현재 운행 중인 trip과 최신 GPS 로그를 함께 반환
  # @return [Array(Trip|nil, GpsLog|nil)]
  def active_trip_with_gps(bus)
    trip = bus.trips.where(ended_at: nil).order(started_at: :desc).first
    return [ nil, nil ] unless trip

    latest_gps = trip.gps_logs.order(recorded_at: :desc).first
    [ trip, latest_gps ]
  end

  # 버스가 지금 어느 정류장 근처인지 판정. geofence event(StopVisit)를 1차 신호로,
  # 없으면 GPS 최근접 계산으로 fallback
  def current_bus_stop(trip, all_stops, latest_gps)
    visit_stop = trip.stop_visits.where(stop: all_stops).order(occurred_at: :desc).first&.stop
    visit_stop || nearest_stop(all_stops, latest_gps)
  end

  # 노선 내 index 번째 정류장의 위치를 0~100%로 반환 (진행바의 점 배치 i/(N-1)*100).
  # sub_pct(0~100): 다음 정류장 방향으로의 보간 비율 — debug_bus 시뮬레이터에서만 사용.
  # 뷰(app/views/stops/show.html.erb)의 점 배치도 이 공식을 그대로 따른다.
  def position_pct(index:, total:, sub_pct: 0)
    return 100 if total <= 1

    [ (((index + sub_pct / 100.0) / (total - 1)) * 100).round, 100 ].min
  end

  # GPS 좌표에 가장 가까운 정류장을 반환 (gps가 nil이면 nil 반환)
  # 경도 방향에 위도 보정(cos factor)을 적용해 실제 거리에 근사
  def nearest_stop(all_stops, gps)
    return nil unless gps

    lat_factor = Math.cos(gps.lat.to_f * Math::PI / 180)
    all_stops.min_by do |s|
      dlat = s.lat.to_f - gps.lat.to_f
      dlng = (s.lng.to_f - gps.lng.to_f) * lat_factor
      dlat**2 + dlng**2
    end
  end
end
