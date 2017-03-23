require 'rails_helper'

RSpec.describe Api::V1::TripsController, type: :controller do
  # This line is necessary to get Devise scoped tests to work.
  before(:each) { @request.env["devise.mapping"] = Devise.mappings[:user] }

  let(:request_headers) { {"X-USER-EMAIL" => user.email, "X-USER-TOKEN" => user.authentication_token} }
  let(:plan_call_params) {JSON.parse(File.read("spec/files/sample_plan_call_basic.json"))}
  let(:multi_plan_call_params) {JSON.parse(File.read("spec/files/sample_plan_call_multiple_trips.json"))}
  let(:taxi_plan_call_params) {JSON.parse(File.read("spec/files/sample_plan_call_taxi.json"))}
  let(:trip) { create(:trip) }
  let(:itinerary) { create(:itinerary)}
  let(:user) { trip.user }
  let(:trip_planner) { TripPlanner.new(trip, trip_types: []) }

  let!(:eligibility) { FactoryGirl.create :eligibility }

  # Stub trip planner methods
  before(:each) do
    allow(trip_planner).to receive(:plan) do
      trip_planner.trip.itineraries << itinerary
    end
    allow(TripPlanner).to receive(:new) { trip_planner }
  end


  it 'creates a trip with a user, origin, destination, trip_time, and arrive_by type' do

    request.headers.merge!(request_headers) # Send user email and token headers
    post :create, params: plan_call_params
    response_body = JSON.parse(response.body)

    trip_request = plan_call_params["itinerary_request"][0]

    expect(response).to be_success
    expect(response_body["user_id"]).to eq(user.id)
    expect(response_body["origin"]).to be
    expect(response_body["destination"]).to be
    expect(response_body["trip_time"].to_datetime).to eq(trip_request["trip_time"].to_datetime)
    expect(response_body["arrive_by"]).to eq(trip_request["departure_type"] == "arrive")
  end

  # it 'allows creation of multiple trips in one request' do
  #   request.headers.merge!(request_headers) # Send user email and token headers
  #   post :create, params: multi_plan_call_params
  #   response_body = JSON.parse(response.body)
  #
  #   trip_requests_count =  multi_plan_call_params["itinerary_request"].count
  #
  #   expect(response).to be_success
  #   expect(response_body.count).to eq(trip_requests_count)
  # end

  it 'allows creation of trips by guest users' do
    post :create, params: plan_call_params
    response_body = JSON.parse(response.body)

    expect(response).to be_success
    expect(response_body["user_id"]).to be_nil
  end

  it 'sends back itineraries' do
    # Stub out trip creation because itinerary planning happens in TripPlanner
    allow(Trip).to receive(:create) { [trip] }

    request.headers.merge!(request_headers) # Send user email and token headers
    post :create, params: plan_call_params
    response_body = JSON.parse(response.body)

    expect(response).to be_success
    expect(response_body["itineraries"]).to be
    expect(response_body["itineraries"].count).to be > 0
  end

  # it 'sends back itineraries for multiple trips' do
  #   # Stub out trip creation because itinerary planning happens in TripPlanner
  #   allow(Trip).to receive(:create) { [trip, trip] }
  #
  #   request.headers.merge!(request_headers) # Send user email and token headers
  #   post :create, params: multi_plan_call_params
  #   response_body = JSON.parse(response.body)
  #
  #   trip_requests_count =  multi_plan_call_params["itinerary_request"].count
  #
  #   expect(response).to be_success
  #   expect(response_body.count).to eq(trip_requests_count)
  #   expect(response_body.map {|t| t["itineraries"]}).to all( be )
  #   expect(response_body.map {|t| t["itineraries"].count}).to all( be > 0 )
  # end

end
