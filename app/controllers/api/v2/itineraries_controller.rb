class Api::V2::ItinerariesController < ApplicationController

  # Replicates the email functionality from Legacy (Except for the Ecolane Stuff)
  def email
    email_address = params[:email_address]
    itinerary_id = params[:itinerary_id]
    itinerary = Itinerary.find(itinerary_id.to_i)
    Rails.logger.info("\n\nIn ItinerariesController.email...\nemail_address: #{email_address}\nitinerary_id: #{itinerary_id}\nitinerary: #{itinerary.inspect}\n\n")
    UserMailer.user_trip_email([email_address], itinerary.trip, itinerary).deliver
    render json: {result: 200}
  end


end
