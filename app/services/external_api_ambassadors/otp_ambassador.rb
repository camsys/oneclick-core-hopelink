class OTPAmbassador
  include OTP

  attr_reader :otp, :trip, :trip_types, :http_request_bundler, :services

  # Translates 1-click trip_types into OTP mode requests
  TRIP_TYPE_DICTIONARY = {
    transit:      { label: :otp_transit, modes: "TRANSIT,WALK" },
    paratransit:  { label: :otp_paratransit, modes: "CAR" },
    car_park:     { label: :otp_car_park, modes: "" },
    taxi:         { label: :otp_car, modes: "CAR" },
    walk:         { label: :otp_walk, modes: "WALK" },
    car:          { label: :otp_car, modes: "CAR" },
    bicycle:      { label: :otp_bicycle, modes: "BICYCLE" },
    uber:         { label: :otp_car, modes: "CAR" },
    lyft:         { label: :otp_car, modes: "CAR" }
  }

  TRIP_TYPE_DICTIONARY_V2 = {
    transit:      { label: :otp_transit, modes: "TRANSIT,WALK" },
    paratransit:  { label: :otp_paratransit, modes: "TRANSIT,WALK,FLEX_ACCESS,FLEX_EGRESS,FLEX_DIRECT" },
    car_park:     { label: :otp_car_park, modes: "CAR_PARK,TRANSIT,WALK" },
    taxi:         { label: :otp_car, modes: "CAR" },
    walk:         { label: :otp_walk, modes: "WALK" },
    car:          { label: :otp_car, modes: "CAR" },
    bicycle:      { label: :otp_bicycle, modes: "BICYCLE" },
    uber:         { label: :otp_car, modes: "CAR" },
    lyft:         { label: :otp_car, modes: "CAR" }
  }

  # Initialize with a trip, an array of trip trips, an HTTP Request Bundler object, 
  # and a scope of available services
  def initialize(
      trip, 
      trip_types=TRIP_TYPE_DICTIONARY.keys, 
      http_request_bundler=HTTPRequestBundler.new, 
      services=Service.published
    )
    
    @trip = trip
    @trip_types = trip_types
    @http_request_bundler = http_request_bundler
    @services = services

    otp_version = Config.open_trip_planner_version
    @trip_type_dictionary = otp_version == 'v1' ? TRIP_TYPE_DICTIONARY : TRIP_TYPE_DICTIONARY_V2
    @request_types = @trip_types.map { |tt|
      @trip_type_dictionary[tt]
    }.compact.uniq
    @otp = OTPService.new(Config.open_trip_planner, otp_version)

    # add http calls to bundler based on trip and modes
    prepare_http_requests.each do |request|
      @http_request_bundler.add(request[:label], request[:url], request[:action])
    end
  end

  # Packages and returns any errors that came back with a given trip request
  def errors(trip_type)
    response = ensure_response(trip_type)
    if response
      response_error = response["error"]
    else
      response_error = "No response for #{trip_type}."
    end
    response_error.nil? ? nil : { error: {trip_type: trip_type, message: response_error} }
  end

  def get_gtfs_ids
    return [] if errors(trip_type)
    itineraries = ensure_response(:transit).itineraries
    return itineraries.map{|i| i.legs.pluck("agencyId")}
  end

  def get_itineraries(trip_type)
    # Use the trip's origin and destination points to plan the trip
    response = @otp.plan(
      [@trip.origin.lat, @trip.origin.lng],
      [@trip.destination.lat, @trip.destination.lng],
      @trip.trip_time,
      @trip.arrive_by,
      options = {}
    )
  
    # Log the full response to compare with previous responses
    Rails.logger.info "Full GraphQL response: #{response.inspect}"
  
    # Return an empty array if there are errors or no plan data
    unless response["data"] && response["data"]["plan"]
      Rails.logger.error "No plan data in response: #{response.inspect}"
      return []
    end
  
    # Log the extracted itineraries for comparison
    itineraries = response["data"]["plan"]["itineraries"]
    Rails.logger.info "Extracted itineraries from GraphQL response: #{itineraries.inspect}"
  
    # Map and convert each itinerary, compact to remove any nil entries
    itineraries.map do |i|
      convert_itinerary(i, trip_type)
    end.compact
  end
  

  # Extracts a trip duration from the OTP response.
  def get_duration(trip_type)
    return 0 if errors(trip_type)
    itineraries = ensure_response(trip_type).itineraries
    return itineraries[0]["duration"] if itineraries[0]
    0
  end

  # Extracts a trip distance from the OTP response.
  def get_distance(trip_type)
    return 0 if errors(trip_type)
    itineraries = ensure_response(trip_type).itineraries
    return extract_distance(itineraries[0]) if itineraries[0]
    0
  end

  def max_itineraries(trip_type_label)
    quantity_config = {
      otp_car: Config.otp_itinerary_quantity,
      otp_walk: Config.otp_itinerary_quantity,
      otp_bicycle: Config.otp_itinerary_quantity,
      otp_car_park: Config.otp_car_park_quantity,
      otp_transit: Config.otp_transit_quantity,
      otp_paratransit: Config.otp_paratransit_quantity
    }

    quantity_config[trip_type_label]
  end

  # Dead Code? - Drew 02/16/2023
  # def get_request_url(request_type)
  #   @otp.plan_url(format_trip_as_otp_request(request_type))
  # end

  private

  # Prepares a list of HTTP requests for the HTTP Request Bundler, based on request types
  def prepare_http_requests
    @request_types.map do |request_type|
      {
        label: request_type[:label],
        url: @otp.plan_url(format_trip_as_otp_request(request_type)),
        action: :get
      }
    end
  end

  # Formats the trip as an OTP request based on trip_type
  def format_trip_as_otp_request(trip_type)
    num_itineraries = max_itineraries(trip_type[:label])
    {
      from: [@trip.origin.lat, @trip.origin.lng],
      to: [@trip.destination.lat, @trip.destination.lng],
      trip_time: @trip.trip_time,
      arrive_by: @trip.arrive_by,
      label: trip_type[:label],
      options: { 
        mode: trip_type[:modes],
        num_itineraries: num_itineraries
      }
    }
  end

  # Fetches responses from the HTTP Request Bundler, and packages
  # them in an OTPResponse object
  def ensure_response(trip_type)
    trip_type_label = @trip_type_dictionary[trip_type][:label]
    response = @http_request_bundler.response(trip_type_label)
    status_code = @http_request_bundler.response_status_code(trip_type_label)
    
    if status_code && status_code == '200'
      otp.unpack(response)
    else
      {"error" => "Http Error #{status_code}"}
    end 
  end

  def convert_itinerary(otp_itin, trip_type)
    associate_legs_with_services(otp_itin)
    itin_has_invalid_leg = otp_itin.legs.detect{ |leg| 
      leg['serviceName'] && leg['serviceId'].nil?
    }
    return nil if itin_has_invalid_leg

    service_id = otp_itin.legs
                          .detect{ |leg| leg['serviceId'].present? }
                          &.fetch('serviceId', nil)

    return {
      start_time: Time.at(otp_itin["startTime"].to_i/1000).in_time_zone,
      end_time: Time.at(otp_itin["endTime"].to_i/1000).in_time_zone,
      transit_time: get_transit_time(otp_itin, trip_type),
      walk_time: get_walk_time(otp_itin, trip_type),
      wait_time: get_wait_time(otp_itin),
      walk_distance: get_walk_distance(otp_itin),
      cost: extract_cost(otp_itin, trip_type),
      legs: otp_itin.legs.to_a,
      trip_type: trip_type, #TODO: Make this smarter
      service_id: service_id
    }
  end  
  


# Updated associate_legs_with_services method to handle the hash format
def associate_legs_with_services(otp_itin)
  Rails.logger.info "Associating legs with services for OTP itinerary: #{otp_itin.inspect}"
  
  otp_itin['plan']['itineraries'].each do |itinerary|
    itinerary['legs'] ||= []
    
    # Modify each leg in this itinerary
    itinerary['legs'] = itinerary['legs'].map do |leg|
      svc = get_associated_service_for(leg)

      # Adjust based on paratransit mode
      if !leg['mode'].include?('FLEX') && leg['boardRule'] == 'mustPhone'
        leg['mode'] = 'FLEX_ACCESS'
      end

      if svc
        leg['serviceId'] = svc.id
        leg['serviceName'] = svc.name
        leg['serviceFareInfo'] = svc.url
        leg['serviceLogoUrl'] = svc.full_logo_url
        leg['serviceFullLogoUrl'] = svc.full_logo_url(nil)
      else
        leg['serviceName'] = (leg['agencyName'] || leg['agencyId'])
      end
  
      leg
    end
  end
end

  
  def get_associated_service_for(leg)
    svc = nil
    leg ||= {}
    gtfs_agency_id = leg['agencyId']
    gtfs_agency_name = leg['agencyName']

    # If gtfs_agency_id is not nil, first attempt to find the service by its GTFS agency ID.
    svc ||= Service.find_by(gtfs_agency_id: gtfs_agency_id) if gtfs_agency_id

    if svc
      # If a service is found by ID, we need to check if it's within the list of permitted services.
      return @services.detect { |s| s.id == svc.id }
    else
      # If we didn't find a service by its ID, and if gtfs_agency_name is not nil, then we try to find a service by its GTFS agency name.
      return @services.find_by(name: gtfs_agency_name) if gtfs_agency_name
    end
  end  
   

  # Calculates the total time spent on transit legs with logger statements for debugging
  def get_transit_time(otp_itin, trip_type)
    
    if trip_type.in? [:car, :bicycle]
      Rails.logger.info("Trip type is #{trip_type}, returning walkTime: #{otp_itin['walkTime']}")
      return otp_itin["walkTime"]
    else
      Rails.logger.info("Calculating transit time for trip type: #{trip_type}")
  
      # Define acceptable transit modes
      transit_modes = ["TRANSIT", "BUS", "TRAM", "RAIL", "SUBWAY", "FERRY"]
  
      # Initialize total transit time
      total_transit_time = 0
  
      otp_itin["legs"].each do |leg|
        Rails.logger.info("Leg mode: #{leg['mode']}")
        
        if transit_modes.include?(leg["mode"])
          start_time = leg["startTime"]
          end_time = leg["endTime"]
  
          if start_time && end_time
            leg_duration = (end_time - start_time) / 1000 # Convert milliseconds to seconds
            Rails.logger.info("Transit leg found with startTime: #{start_time}, endTime: #{end_time}, duration (s): #{leg_duration}")
            total_transit_time += leg_duration
          else
            Rails.logger.warn("Missing start or end time for transit leg: #{leg.inspect}")
          end
        else
          Rails.logger.info("Non-transit leg skipped with mode: #{leg['mode']}")
        end
      end
  
      Rails.logger.info("Total transit time calculated: #{total_transit_time} seconds")
      return total_transit_time
    end
  end
  

  # OTP returns car and bicycle time as walk time
  def get_walk_time otp_itin, trip_type
    if trip_type.in? [:car, :bicycle]
      return 0
    else
      return otp_itin["walkTime"]
    end
  end

  # Returns waiting time from an OTP itinerary
  def get_wait_time otp_itin
    return otp_itin["waitingTime"]
  end

  def get_walk_distance otp_itin
    return otp_itin["walkDistance"]
  end

  def extract_cost(itinerary, trip_type)
    # Only process fares for relevant trip types (like transit).
    return 0.0 unless [:transit, :bus, :rail].include?(trip_type)
  
    # Try to fetch fare from itinerary-level fares.
    fare = itinerary["fares"]&.first
    if fare
      return fare["cents"] / 100.0
    end
  
    # Fallback to fetching fare from leg-level fareProducts.
    itinerary["legs"].each do |leg|
      leg["fareProducts"]&.each do |product|
        if product["product"]["price"]
          return product["product"]["price"]["amount"]
        end
      end
    end
  
    # Default to zero if no fare information is found.
    0.0
  end
  

  # Extracts total distance from OTP itinerary
  # default conversion factor is for converting meters to miles
  def extract_distance(otp_itin, trip_type=:car, conversion_factor=0.000621371)
    otp_itin.legs.sum_by(:distance) * conversion_factor
  end


end
