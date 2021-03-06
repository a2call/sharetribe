require "spec_helper"

def create_version(community_id, structure, version_number)
  s = structure.deep_dup
  s["page"]["title"] = {value: "Title version #{version_number}"}
  CustomLandingPage::LandingPageStore.create_version!(community_id, version_number, JSON.generate(s))
end

def release_version(community_id, version_number)
  CustomLandingPage::LandingPageStore.release_version!(community_id, version_number)
end

# Populate category ids in all category sections
def populate_categories(structure, category_ids)
  struct = structure.deep_dup
  struct["sections"].each do |s|
    next unless s["kind"] == "categories"

    s["categories"].each_with_index do |c, i|
      c["category"]["id"] = category_ids[i]
    end
  end
  struct
end

# Populate listing ids in all listing sections
def populate_listings(structure, listing_ids)
  struct = structure.deep_dup
  struct["sections"].each do |s|
    next unless s["kind"] == "listings"

    s["listings"].each_with_index do |l, i|
      l["listing"]["id"] = listing_ids[i]
    end
  end
  struct
end

def expect_string(url, string)
  get url

  expect(response.status).to eq(200)
  expect(response.body).to match(/#{string}/)
end

def expect_controller(url, controller_name, action_name)
  get url

  expect(controller.controller_name).to eq(controller_name)
  expect(controller.action_name).to eq(action_name)
end

describe "Landing page", type: :request do
  before(:all) do
    # For performance reasons, we set up data in before(:all) so we need to clean it
    # up ourselves. before(:all) runs outside of transaction, by default.
    DatabaseCleaner.start

    @domain = "market.custom.org"
    @community = FactoryGirl.create(:community, :domain => @domain, use_domain: true)
    @community.reload

    10.times do
      FactoryGirl.create(:category, community_id: @community.id)
    end

    10.times do
      FactoryGirl.create(:listing, community_id: @community.id)
    end

    sample_structure = JSON.parse(CustomLandingPage::ExampleData::TEMPLATE_STR)
    sample_structure = populate_categories(sample_structure, @community.categories.map(&:id))
    sample_structure = populate_listings(sample_structure, @community.listings.map(&:id))

    create_version(@community.id, sample_structure, 1)
    create_version(@community.id, sample_structure, 2)

    CustomLandingPage::LandingPageStore.create_landing_page!(@community.id)
  end

  after(:all) do
    # For performance reasons, we set up data in before(:all) so we need to clean it
    # up ourselves. before(:all) runs outside of transaction, by default.
    DatabaseCleaner.clean
  end

  context "when not released" do
    it "index routes to homepage" do
      expect_controller("http://#{@domain}", "homepage", "index")
    end

    it "search path redirects to homepage" do
      get "http://#{@domain}/s"

      expect(response.status).to eq(307)
      expect(response.location).to eq("http://#{@domain}/")
    end

    it "preview routes to landing page preview" do
      expect_controller("http://#{@domain}/_lp_preview?preview_version=1", "landing_page", "preview")
    end

    it "renders correct preview" do
      expect_string("http://#{@domain}/_lp_preview?preview_version=1", "<title>Title version 1</title>")
      expect_string("http://#{@domain}/_lp_preview?preview_version=2", "<title>Title version 2</title>")
    end
  end

  context "when released" do
    before(:all) do
      release_version(@community.id, 1)
    end

    it "index routes to landing page" do
      expect_controller("http://#{@domain}", "landing_page", "index")
    end

    it "search path routes to search" do
      expect_controller("http://#{@domain}/s", "homepage", "index")
    end

    it "shows correct landing page version" do
      expect_string("http://#{@domain}", "<title>Title version 1</title>")
    end

    it "preview routes to landing page preview" do
      expect_controller("http://#{@domain}/_lp_preview?preview_version=1", "landing_page", "preview")
    end

    context "new version" do
      it "shows correct landing page version" do
        expect_string("http://#{@domain}", "<title>Title version 1</title>")

        release_version(@community.id, 2)

        expect_string("http://#{@domain}", "<title>Title version 2</title>")
      end
    end

    describe "caching" do
      before(:all) do
        Rails.cache.clear

        get "http://#{@domain}"

        @etag = response.headers["Etag"]
        @last_modified = response.headers["Last-Modified"]
      end

      before(:each) do
        @orig_cache_time = APP_CONFIG.clp_cache_time.to_i
        APP_CONFIG.clp_cache_time = 60

        # Access controller to make sure it is loaded (e.g. if previous tests are disabled)
        _ = LandingPageController
        # Stub CACHE_TIME constant, because controller has already been loaded
        stub_const("LandingPageController::CACHE_TIME", 60.seconds)
      end

      after(:each) do
        APP_CONFIG.clp_cache_time = @orig_cache_time
        stub_const("LandingPageController::CACHE_TIME", @orig_cache_time.seconds)
      end

      it "subsequent requests are served from cache" do
        get "http://#{@domain}"

        expect(response.headers["X-CLP-Cache"]).to eq("1")
        expect(response.status).to eq(200)
      end

      it "request with correct etag returns 'not modified'" do
        get "http://#{@domain}", nil, {"If-None-Match" => @etag}

        expect(response.status).to eq(304)
      end

      it "request with incorrect etag returns 200" do
        # incorrect etag is md5("foobar")
        get "http://#{@domain}", nil, {"If-None-Match" => "14758f1afd44c09b7992073ccf00b43d"}

        expect(response.status).to eq(200)
      end

      it "request with correct Last-Modified returns 'not modified'" do
        get "http://#{@domain}", nil, {"If-Modified-Since" => @last_modified}

        expect(response.status).to eq(304)
      end

      it "request with past Last-Modified returns 200" do
        past = Time.parse(@last_modified) - 10.minutes
        get "http://#{@domain}", nil, {"If-Modified-Since" => past.to_s}

        expect(response.status).to eq(200)
      end

      describe "cache expiration" do
        before(:all) { Rails.cache.clear }

        before(:each) do
          APP_CONFIG.clp_cache_time = 5
          # Stub CACHE_TIME constant, because controller has already been loaded
          stub_const("LandingPageController::CACHE_TIME", 5.seconds)
        end

        after(:each) do
          APP_CONFIG.clp_cache_time = @orig_cache_time
          stub_const("LandingPageController::CACHE_TIME", @orig_cache_time.seconds)
        end

        it "after configured time" do
          get "http://#{@domain}"

          expect(response.status).to eq(200)
          expect(response.headers["X-CLP-Cache"]).to eq("0")

          # wait for cache to expire
          sleep(APP_CONFIG.clp_cache_time + 1)

          get "http://#{@domain}"

          expect(response.status).to eq(200)
          expect(response.headers["X-CLP-Cache"]).to eq("0")
        end
      end
    end
  end

end
