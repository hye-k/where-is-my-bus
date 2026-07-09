module Admin
  class StopsController < BaseController
    before_action :set_stop, only: %i[show edit update destroy sync_geofence mock_visit]

    def index
      @stops = Stop.includes(route: { area: :region }).all
      @stops = @stops.where(route_id: params[:route_id]) if params[:route_id].present?
    end

    def show
    end

    def new
      @stop = Stop.new(route_id: params[:route_id])
    end

    def create
      @stop = Stop.new(stop_params)
      if @stop.save
        attempt_geofence_sync
        redirect_to admin_stops_path(route_id: @stop.route_id), notice: "정류장이 등록되었습니다."
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit
    end

    def update
      if @stop.update(stop_params)
        attempt_geofence_sync
        redirect_to admin_stops_path(route_id: @stop.route_id), notice: "정류장이 수정되었습니다."
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      route_id = @stop.route_id
      result = TraccarGeofenceSync.destroy(@stop)
      @stop.destroy
      flash[:alert] = result.error if result.failure?
      redirect_to admin_stops_path(route_id: route_id), notice: "정류장이 삭제되었습니다.", status: :see_other
    end

    def sync_geofence
      result = TraccarGeofenceSync.call(@stop)
      if result.failure?
        flash[:alert] = result.error
      else
        flash[:notice] = "geofence 동기화에 성공했습니다."
      end
      redirect_to admin_stop_path(@stop)
    end

    # 개발용: 실제 Traccar 서버 없이 이 정류장에 버스 도착(geofence enter) 이벤트를 발생시킨다.
    # 시민 진행바의 버스 아이콘이 이 정류장으로 이동하는지 눈으로 확인하는 도구.
    def mock_visit
      return head :not_found unless Rails.env.local?

      bus = @stop.route&.bus
      unless bus
        flash[:alert] = "이 노선에 배정된 버스가 없어 mock 이벤트를 발생시킬 수 없습니다."
        return redirect_to admin_stop_path(@stop)
      end

      # 활성 trip(운행 중)이 없으면 positions/events 수신 로직과 동일하게 자동 생성
      trip = bus.find_or_create_active_trip!

      begin
        trip.stop_visits.create!(stop: @stop, event_type: "enter", occurred_at: Time.current)
      rescue ActiveRecord::RecordNotUnique
        # 같은 초에 중복 클릭 — 이미 해당 정류장에 visit이 있으므로 목적 달성, 무시
      end

      # 목록/상세 어디서 눌러도 원래 화면으로 돌아오게 한다(반복 테스트 편의)
      redirect_back_or_to admin_stop_path(@stop), notice: "#{@stop.name}에 버스 도착(mock)을 발생시켰습니다."
    end

    private

    def set_stop
      @stop = Stop.find(params[:id])
    end

    def stop_params
      params.require(:stop).permit(:route_id, :name, :sequence, :lat, :lng, :avg_travel_seconds, :name_en)
    end

    def attempt_geofence_sync
      result = TraccarGeofenceSync.call(@stop)
      flash[:alert] = result.error if result.failure?
    end
  end
end
