# 개발 환경 가이드

## 1. Rails 환경 모델 (development / test / production)

Rails는 **프로세스 하나가 동시에 여러 환경일 수 없다**는 전제로 동작한다. `RAILS_ENV`(또는 `RACK_ENV`) 환경변수 값 하나로 그 프로세스 전체의 환경이 정해지고, `Rails.env`는 이 값을 읽는 wrapper일 뿐이다.

- `bin/rails server` / `bin/rails console` → 기본 `RAILS_ENV=development`, `storage/development.sqlite3` 사용.
- `bin/rails test` → `test/test_helper.rb`가 `ENV["RAILS_ENV"] ||= "test"`로 강제, `storage/test.sqlite3`를 쓰는 **완전히 별도의 프로세스**로 뜬다.
- `config/environments/{development,test,production}.rb`가 각각 존재하듯, 이 세 환경은 설정·DB가 서로 분리되어 있다.

### `config/routes.rb`는 부팅 시 딱 한 번 평가된다

`Rails.application.routes.draw do ... end` 블록은 앱이 뜨는 시점(요청마다가 아니라!)에 한 번 실행된다. 그래서:

```ruby
if Rails.env.development?
  post "/r/:region_slug/:stop_id/debug_bus", to: "stops#debug_bus"
end
```

이렇게 감싼 라우트는 `RAILS_ENV=test`로 뜬 프로세스(`bin/rails test`)에서는 **그 라우트 자체가 존재하지 않는다.** 이 라우트의 path 헬퍼(`stop_debug_bus_path` 등)를 테스트 코드에서 부르면 정의되지 않은 메서드 에러가 난다 — 테스트 안에서 아무리 다르게 처리해도 되살릴 수 없다. 부팅 시점에 이미 고정되기 때문이다.

### `Rails.env.local?`

`ActiveSupport::EnvironmentInquirer`(Rails core, `activesupport` gem)에 1급 API로 정의되어 있다:

```ruby
LOCAL_ENVIRONMENTS = %w[ development test ]

def local?
  @local  # env == "development" || env == "test"
end
```

즉 **development와 test를 "로컬"이라는 한 카테고리로 묶는 것 자체가 Rails의 공식 컨벤션**이다. "프로덕션엔 노출하면 안 되지만, 서버로 켜서 보든 테스트로 검증하든 개발 중엔 필요한 기능"을 가드할 때 쓰는 표준 방법이 `local?`이다.

### 이 프로젝트의 실제 선택 기준

| 기능 | 가드 | 이유 |
|---|---|---|
| `StopsController#debug_bus` (시민 페이지 디버그 패널, GPS 시뮬레이터) | `Rails.env.development?` | 컨트롤러 테스트가 없음 — test 환경에서 라우트가 없어도 아무것도 안 깨짐 |
| `Admin::StopsController#mock_visit` (admin mock 이벤트 버튼) | `Rails.env.local?` | 컨트롤러 테스트 4건이 이 라우트를 test 환경에서 직접 호출함 — `local?`이 아니면 라우팅 에러로 테스트가 깨짐 |

**규칙**: 그 기능을 테스트가 직접 호출해야 한다면 `local?`, 아니면(수동으로만 확인하는 도구라면) `development?`로 충분하다. 필요 없는데 `local?`로 넓히는 건 하지 않는다(불필요한 변경 지양).

---

## 2. 로컬 Ruby 툴체인 없이 개발하기 (Docker)

`.tool-versions`가 요구하는 Ruby 4.0.2가 없는 장비를 위한 컨테이너 개발 환경이 `Dockerfile.dev` + `compose.yaml`로 준비되어 있다. asdf 등으로 Ruby를 직접 설치할 수 있으면 이 섹션은 필요 없다 — README의 "시작하기"를 따르면 된다.

```bash
docker compose build                              # 최초 1회 이미지 빌드 (gem 설치 포함)
docker compose run --rm web bin/rails test        # 전체 테스트
docker compose run --rm web bin/rails test PATH   # 특정 파일만
docker compose run --rm web bin/rubocop           # 린트
docker compose up                                 # 개발 서버 → http://localhost:3000
```

- 소스는 볼륨 마운트되므로 컨테이너를 재빌드하지 않아도 코드 변경이 바로 반영된다.
- gem은 named volume(`bundle`)에 영속되어 컨테이너를 지워도 재설치가 필요 없다.
- `bin/rails tailwindcss:build`로 CSS를 빌드해야 스타일이 반영된다 — `compose up`의 기본 command에 이미 포함되어 있지만, 새 Tailwind 유틸리티 클래스를 뷰에 추가한 뒤 컨테이너를 재시작하지 않고 확인하려면 `docker compose exec web bin/rails tailwindcss:build`를 수동으로 한 번 더 돌려야 한다(v4는 사용된 클래스만 정적으로 컴파일하므로, 새 클래스는 재빌드 전까지 CSS에 없다).

### TLS를 가로채는 네트워크 환경이라면

사내 프록시 등으로 HTTPS 트래픽이 가로채지는 네트워크에서는 `bundle install`이 `rubygems.org` 인증서 검증에서 실패할 수 있다. 그 경우 CA 인증서 번들을 저장소 루트에 `ca-bundle.pem`으로 두면 `Dockerfile.dev`가 이미지 빌드 시 자동으로 시스템 신뢰 저장소에 추가한다. 이 파일은 장비별 설정이라 `.gitignore` 대상이며, 파일이 없어도(대부분의 환경) 빌드에는 영향이 없다.
