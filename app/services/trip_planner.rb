###
# TRIP PLANNER is in charge of handling the business logic around building
# itineraries for a trip, and pulling in information from various 3rd-party
# APIs.

class TripPlanner

  # Constant list of trip types that can be planned.
  TRIP_TYPES = Trip::TRIP_TYPES
  attr_reader :options, :router, :errors, 
              :trip_types, :available_services, :http_request_bundler,
              :relevant_purposes, :relevant_accommodations, :relevant_eligibilities,
              :only_filters, :except_filters, :filters
  attr_accessor :trip, :master_service_scope

  # Initialize with a Trip object, and an options hash
  def initialize(trip, options={})
    @trip = trip
    @options = options
    @trip_types = (options[:trip_types] || TRIP_TYPES) & TRIP_TYPES
    Rails.logger.info("TripPlanner initialized with trip_types: #{@trip_types} and options: #{@options.inspect}")
    if Config.open_trip_planner_version != 'v1' && (@trip_types.include?(:car) && @trip_types.include?(:transit))
      @trip_types.push(:car_park)
    end    
    @purpose = Purpose.find_by(id: @options[:purpose_id])


    @errors = []
    @paratransit_drive_time_multiplier = Config.paratransit_drive_time_multiplier.to_f
    @master_service_scope = options[:available_services] || Service.all # Allow pre-filtering of available services
    # This bundler is passed to the ambassadors, so that all API calls can be made asynchronously
    @http_request_bundler = options[:http_request_bundler] || HTTPRequestBundler.new
    @relevant_eligibilities = @relevant_purposes = @relevant_accommodations = []

    # Allow user to request that certain service availability filters be included or skipped
    @only_filters = (options[:only_filters] || Service::AVAILABILITY_FILTERS) & Service::AVAILABILITY_FILTERS
    @except_filters = options[:except_filters] || []
    @filters = @only_filters - @except_filters
    
    # Initialize ambassadors if passed as options
    @router = options[:router] #This is the otp_ambassador
    @taxi_ambassador = options[:taxi_ambassador]
    @uber_ambassador = options[:uber_ambassador]
    @lyft_ambassador = options[:lyft_ambassador]
  end

  # Constructs Itineraries for the Trip based on the options passed
  def plan
    Rails.logger.info("Starting plan method for trip: #{@trip.id}")

    # Identify available services and set instance variable for use in building itineraries
    set_available_services

    # Sets up external ambassadors
    prepare_ambassadors
    Rails.logger.info("Ambassadors prepared.")

    # Build itineraries for each requested trip_type, then save the trip
    build_all_itineraries
    Rails.logger.info("All itineraries built.")

    # Run through post-planning filters
    filter_itineraries
    no_transit = true
    no_paratransit = true
    @trip.itineraries.each do |itin|
      if itin.trip_type == "transit"
        no_transit = false
      elsif itin.trip_type == "paratransit"
        no_paratransit = false
      end
    end
    @trip.no_valid_services = no_paratransit && no_transit
    @trip.save
  end

  # Set up external API ambassadors
  def prepare_ambassadors
    # Set up external API ambassadors for route finding and fare calculation
    @router ||= OTPAmbassador.new(@trip, @trip_types, @http_request_bundler, @available_services[:transit].or(@available_services[:paratransit]))
    @taxi_ambassador ||= TFFAmbassador.new(@trip, @http_request_bundler, services: @available_services[:taxi])
    @uber_ambassador ||= UberAmbassador.new(@trip, @http_request_bundler)
    @lyft_ambassador ||= LyftAmbassador.new(@trip, @http_request_bundler)
  end

  # Identifies available services for the trip and requested trip_types, and sorts them by service type
  # Only filter by filters included in the @filters array
  def set_available_services
    # Start with the scope of all services available for public viewing
    @available_services = @master_service_scope.published

    # Only select services that match the requested trip types
    @available_services = @available_services.by_trip_type(*@trip_types)

    # Only select services that your age makes you eligible for
    if @trip.user and @trip.user.age 
      @available_services = @available_services.by_max_age(@trip.user.age).by_min_age(@trip.user.age)
    end

    Rails.logger.info "Initial available services count: #{@available_services.count}"

    # Apply remaining filters if not in travel patterns mode.
    # Services using travel patterns are checked through travel patterns API.
    if Config.dashboard_mode != 'travel_patterns'
      # Find all the services that are available for your time and locations
      @available_services = @available_services.available_for(@trip, only_by: (@filters - [:purpose, :eligibility, :accommodation]))

      # Pull out the relevant purposes and eligibilities of these services
      @relevant_purposes = (@available_services.collect { |service| service.purposes }).flatten.uniq
      @relevant_eligibilities = (@available_services.collect { |service| service.eligibilities }).flatten.uniq.sort_by { |elig| elig.rank }

      # Now finish filtering by purpose and eligibility
      @available_services = @available_services.available_for(@trip, only_by: (@filters & [:purpose, :eligibility]))

      # Filter accommodations only for paratransit services
      @relevant_accommodations = Accommodation.all.ordered_by_rank
      paratransit_services = @available_services.where(type: 'Paratransit')
      paratransit_services = paratransit_services.available_for(@trip, only_by: [:accommodation])

      # Merge the filtered paratransit services back into @available_services
      non_paratransit_services = @available_services.where.not(type: 'Paratransit')
      @available_services = non_paratransit_services.or(paratransit_services)
    else
      # Currently there's only one service per county, users are only allowed to book rides for their home service, and er only use paratransit services, so this may break
      options = {}
      options[:origin] = {lat: @trip.origin.lat, lng: @trip.origin.lng} if @trip.origin
      options[:destination] = {lat: @trip.destination.lat, lng: @trip.destination.lng} if @trip.destination
      options[:purpose_id] = @trip.purpose_id if @trip.purpose_id
      options[:date] = @trip.trip_time.to_date if @trip.trip_time
      
      @available_services.joins(:travel_patterns).merge(TravelPattern.available_for(options)).distinct
      @relevant_eligibilities = (@available_services.collect { |service| service.eligibilities }).flatten.uniq.sort_by{ |elig| elig.rank }
      @relevant_accommodations = Accommodation.all.ordered_by_rank
      @available_services = @available_services.available_for(@trip, only_by: [:eligibility]) #, :accommodation])
    end

    # Now convert into a hash grouped by type
    @available_services = available_services_hash(@available_services)

  end
  
  # Group available services by type, returning a hash with a key for each
  # service type, and one for all the available services
  def available_services_hash(services)
    Service::SERVICE_TYPES.map do |t| 
      [t.underscore.to_sym, services.where(type: t)]
    end.to_h.merge({ all: services })
  end
  
  # Builds itineraries for all trip types
  def build_all_itineraries
    Rails.logger.info("Building all itineraries for trip types: #{@trip_types}")
    
    # Log the trip types being processed to ensure they are correct and unique
    @trip_types.each { |t| Rails.logger.info("Processing trip type: #{t}") }
  
    # Build itineraries for each trip type
    trip_itineraries = @trip_types.flat_map do |t|
      Rails.logger.info("Calling build_itineraries for trip type: #{t}")
      build_itineraries(t)
    end
  
    Rails.logger.info("Reclassifying itineraries based on legs")
    trip_itineraries.each do |itin|
      if itin.legs&.any?
        all_walk = itin.legs.all? { |leg| leg["mode"] == "WALK" }
        has_transit = itin.legs.any? { |leg| leg["mode"] != "WALK" }
    
        # Adjust trip type
        if all_walk && itin.trip_type == "transit"
          Rails.logger.info("Reclassifying walk-only itinerary as walk.")
          itin.trip_type = "walk"
        elsif has_transit && itin.trip_type == "walk"
          Rails.logger.info("Reclassifying transit itinerary as transit.")
          itin.trip_type = "transit"
        end
      else
        Rails.logger.warn("Skipping reclassification for itinerary with no legs: #{itin.inspect}")
      end
    end    
  
    # Separate new and existing itineraries
    new_itineraries = trip_itineraries.reject(&:persisted?)
    old_itineraries = trip_itineraries.select(&:persisted?)
  
    # Log categorized itineraries
    Rails.logger.info("New itineraries count: #{new_itineraries.count}")
    Rails.logger.info("Old itineraries count: #{old_itineraries.count}")
  
    # Save old itineraries and associate new ones with the trip
    Itinerary.transaction do
      old_itineraries.each do |itin|
        Rails.logger.info("Saving existing itinerary: #{itin.inspect}")
        itin.save!
      end
  
      Rails.logger.info("Adding new itineraries to trip: #{new_itineraries.map(&:inspect)}")
      @trip.itineraries += new_itineraries
    end
  
    Rails.logger.info("All itineraries successfully processed for trip: #{@trip.id}")
  end

  # Additional sanity checks can be applied here.
  def filter_itineraries
    Rails.logger.info("Filtering itineraries for trip #{@trip.id}. Initial count: #{@trip.itineraries.count}")

    walk_seen = false
    max_walk_minutes = Config.max_walk_minutes
    max_walk_distance = Config.max_walk_distance
    itineraries = @trip.itineraries.map do |itin|

      ## Test: Make sure we never exceed the maximium walk time
      if itin.walk_time and itin.walk_time > max_walk_minutes*60
        next
      end

      ## Test: Make sure that we only ever return 1 walk trip
      if itin.walk_time and itin.duration and itin.walk_time == itin.duration 
        if walk_seen
          next 
        else 
          walk_seen = true 
        end
      end

      # Test: Filter out walk-only itineraries when walking is deselected
      if !@trip.itineraries.map(&:trip_type).include?('walk') && itin.trip_type == 'transit' && 
        itin.legs.all? { |leg| leg['mode'] == 'WALK' } && 
        itin.walk_distance >= itin.legs.first['distance']
      next
      end

      # Test: Filter out itineraries where user has de-selected walking as a trip type, kept transit, and any walking leg in the transit trip exceeds the maximum walk distance
      if !@trip.itineraries.map(&:trip_type).include?('walk') && itin.trip_type == 'transit' && itin.legs.detect { |leg| leg['mode'] == 'WALK' && leg["distance"] > max_walk_distance }
        next
      end

      # Test: Only apply max_walk_distance if walking is not selected as a trip type
      if !@trip.itineraries.map(&:trip_type).include?('walk')
        if itin.trip_type == 'transit' && itin.legs.any? { |leg| leg['mode'] == 'WALK' && leg["distance"] > max_walk_distance }
          next
        end
      end

      ## We've passed all the tests
      itin 
    end
    itineraries.delete(nil)

    @trip.itineraries = itineraries
    Rails.logger.info("Filtered itineraries count: #{@trip.itineraries.count}")
  end

  # Calls the requisite trip_type itineraries method
  def build_itineraries(trip_type)
    catch_errors(trip_type)
    self.send("build_#{trip_type}_itineraries")
  end

  # Catches errors associated with a trip type and saves them in @errors
  def catch_errors(trip_type)
    errors = @router.errors(trip_type)
    @errors << errors if errors
  end

  # # # Builds transit itineraries, using OTP by default
  def build_transit_itineraries
    Rails.logger.info("Building transit itineraries...")
    build_fixed_itineraries :transit
  end

  def build_car_park_itineraries
    build_fixed_itineraries :car_park
  end

  # Builds walk itineraries, using OTP by default
  def build_walk_itineraries
    build_fixed_itineraries :walk
  end

  def build_car_itineraries
    build_fixed_itineraries :car
  end

  def build_bicycle_itineraries
    build_fixed_itineraries :bicycle
  end

  # Builds paratransit itineraries for each service, populates transit_time based on OTP response
  def build_paratransit_itineraries
    Rails.logger.info("Starting build_paratransit_itineraries...")
  
    return [] unless @available_services[:paratransit].present?
  
    # OTP-based itineraries
    otp_itineraries = build_fixed_itineraries(:paratransit).select { |itin| itin.service_id.present? }
  
    # Build itineraries from OTP itineraries
    router_itineraries = otp_itineraries.map do |itin|
  
      # Find or initialize an itinerary for the service
      itinerary = Itinerary.left_joins(:booking)
                            .where(bookings: { id: nil })
                            .find_or_initialize_by(
                              service_id: itin.service_id,
                              trip_type: :paratransit,
                              trip_id: @trip.id
                            )
      calculated_duration = @router.get_duration(:paratransit) * @paratransit_drive_time_multiplier
  
      # Assign attributes from service and OTP response
      itinerary.assign_attributes({
        assistant: @options[:assistant],
        companions: @options[:companions],
        cost: itin.service.fare_for(@trip, router: @router, companions: @options[:companions], assistant: @options[:assistant]),
        transit_time: calculated_duration
      })
  
      itinerary
    end
  
    # Services that passed accommodations but do not have a gtfs_agency_id
    non_gtfs_services = @available_services[:paratransit].where(gtfs_agency_id: [nil, ""])
  
    non_gtfs_itineraries = non_gtfs_services.map do |svc|
      Rails.logger.info("Processing non-GTFS service ID: #{svc.id}")
    
      # Find or initialize an itinerary for the service
      itinerary = Itinerary.left_joins(:booking)
                            .where(bookings: { id: nil })
                            .find_or_initialize_by(
                              service_id: svc.id,
                              trip_type: :paratransit,
                              trip_id: @trip.id
                            )
    
      # Calculate transit time
      calculated_duration = @router.get_duration(:paratransit) * @paratransit_drive_time_multiplier
    
      # Assign attributes for the itinerary
      itinerary.assign_attributes({
        assistant: @options[:assistant],
        companions: @options[:companions],
        cost: svc.fare_for(@trip, router: @router, companions: @options[:companions], assistant: @options[:assistant]),
        transit_time: calculated_duration
      })
    
      itinerary
    end    
  
    # Combine and return both sets of itineraries
    all_itineraries = (router_itineraries + non_gtfs_itineraries).compact
    Rails.logger.info("Final built itineraries count: #{all_itineraries.count}")
    all_itineraries
  end  
  
  
  # Builds taxi itineraries for each service, populates transit_time based on OTP response
  def build_taxi_itineraries
    return [] unless @available_services[:taxi] # Return an empty array if no taxi services are available
    @available_services[:taxi].map do |svc|
      Itinerary.new(
        service: svc,
        trip_type: :taxi,
        cost: svc.fare_for(@trip, router: @router, taxi_ambassador: @taxi_ambassador),
        transit_time: @router.get_duration(:taxi)
      )
    end
  end

  # Builds an uber itinerary populates transit_time based on OTP response
  def build_uber_itineraries
    return [] unless @available_services[:uber] # Return an empty array if no Uber services are available

    cost, product_id = @uber_ambassador.cost('uberX')

    return [] unless cost

    new_itineraries = @available_services[:uber].map do |svc|
      Itinerary.new(
        service: svc,
        trip_type: :uber,
        cost: cost,
        transit_time: @router.get_duration(:uber)
      )
    end

    new_itineraries.map do |itin|
      UberExtension.new(
        itinerary: itin,
        product_id: product_id
      )
    end

    new_itineraries

  end

  # Builds an uber itinerary populates transit_time based on OTP response
  def build_lyft_itineraries
    return [] unless @available_services[:lyft] # Return an empty array if no taxi services are available

    cost, price_quote_id = @lyft_ambassador.cost('lyft')

    # Don't return LYFT results if there are none.
    return [] if cost.nil? 

    new_itineraries = @available_services[:lyft].map do |svc|
      Itinerary.new(
        service: svc,
        trip_type: :lyft,
        cost: cost,
        transit_time: @router.get_duration(:lyft)
      )
    end

    new_itineraries.map do |itin|
      LyftExtension.new(
        itinerary: itin,
        price_quote_id: price_quote_id
      )
    end

    new_itineraries

  end

  # Generic OTP Call
  def build_fixed_itineraries trip_type
    itineraries = @router.get_itineraries(trip_type)
    itineraries.map { |i| Itinerary.new(i) }
  end

end
