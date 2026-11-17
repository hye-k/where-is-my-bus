require_relative "boot"

require "rails"
# Pick the frameworks you want:
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
require "active_storage/engine"
require "action_controller/railtie"
require "action_mailer/railtie"
require "action_mailbox/engine"
require "action_text/engine"
require "action_view/railtie"
require "action_cable/engine"
require "rails/test_unit/railtie"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module Web
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")

    config.time_zone = "Seoul"
    config.i18n.default_locale = :ko

    # 첨부 파일과 이미지 변환을 쓰지 않아 image_processing gem과 libvips를 뺐다.
    # 이 설정이 없으면 부팅 때마다 image_processing이 없다는 경고가 나온다. 이미지 변환을 쓰게 되면
    # gem "image_processing"을 다시 넣고 이 줄을 지운다.
    config.active_storage.variant_processor = :disabled
    config.i18n.available_locales = [ :ko ]

    # 지역 목록 아래에 표시하는 데이터 출처 문구. 적재한 지역 데이터의 출처에 맞게 배포마다 정한다.
    # 비우면 표시하지 않는다. 문구는 임시다: CC BY의 요구 표기 형식은 이용 조건 원문과 대조하지 않았다.
    config.x.region_data_attribution =
      "데이터 출처: 지역 계층·코드: 국토교통부 법정동코드 · 지역 경계: 브이월드(국토교통부) 법정구역정보 (CC BY)"

    # Don't generate system test files.
    config.generators.system_tests = nil
  end
end
