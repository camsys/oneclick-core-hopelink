require 'rails_helper'

RSpec.describe ItinerarySerializer, type: :serializer do
  let(:transit_itinerary) { create(:transit_itinerary)}
  let(:transit_serializer) { ItinerarySerializer.new(transit_itinerary)}
  let(:transit_serialization) { JSON.parse(ActiveModelSerializers::Adapter.create(transit_serializer).to_json) }

  let(:paratransit_itinerary) { create(:paratransit_itinerary)}
  let(:paratransit_serializer) { ItinerarySerializer.new(paratransit_itinerary)}
  let(:paratransit_serialization) { JSON.parse(ActiveModelSerializers::Adapter.create(paratransit_serializer).to_json) }

  let(:paratransit_service_serialization) do
    JSON.parse(
      ActiveModelSerializers::Adapter.create(
        ServiceSerializer.new(paratransit_itinerary.service)
      ).to_json
    )
  end

  it 'faithfully serializes transit itineraries' do
    expect(transit_serialization["id"]).to eq(transit_itinerary.id)
    expect(transit_serialization["cost"]).to eq(transit_itinerary.cost)
    expect(transit_serialization["walk_time"]).to eq(transit_itinerary.walk_time)
    expect(transit_serialization["transit_time"]).to eq(transit_itinerary.transit_time)
    expect(transit_serialization["start_time"].to_datetime).to eq(transit_itinerary.start_time)
    expect(transit_serialization["end_time"].to_datetime).to eq(transit_itinerary.end_time)
    expect(transit_serialization["legs"]).to eq(transit_itinerary.legs)
  end

  it 'faithfully serializes paratransit itineraries' do
    expect(paratransit_serialization["service"]).to be
    expect(paratransit_serialization["service"]).to eq(paratransit_service_serialization)
  end

end
