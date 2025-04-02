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
    Rails.logger.info("[TripPlanner#plan] Starting plan for trip: #{@trip.id}")
  
    set_available_services
    prepare_ambassadors
  
    Rails.logger.info("[TripPlanner#plan] Available trip types: #{@trip_types}")
    Rails.logger.info("[TripPlanner#plan] Available services: #{@available_services.inspect}")
  
    build_all_itineraries
  
    Rails.logger.info("[TripPlanner#plan] Itineraries after build:")
    @trip.itineraries.each_with_index do |itin, idx|
      Rails.logger.info("[TripPlanner#plan] Itinerary ##{idx}: trip_type=#{itin.trip_type}, service_id=#{itin.service_id}")
      itin.legs&.each_with_index do |leg, i|
        Rails.logger.info("[TripPlanner#plan] └── Leg #{i}: mode=#{leg['mode']}, serviceType=#{leg['serviceType']}")
      end
    end
  
    filter_itineraries
  
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
    Rails.logger.info "Available services: #{@available_services}"

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
      Rails.logger.info "origin: #{options[:origin]}"
      options[:destination] = {lat: @trip.destination.lat, lng: @trip.destination.lng} if @trip.destination
      Rails.logger.info "destination: #{options[:destination]}"
      options[:purpose_id] = @trip.purpose_id if @trip.purpose_id
      options[:date] = @trip.trip_time.to_date if @trip.trip_time
      
      @available_services.joins(:travel_patterns).merge(TravelPattern.available_for(options)).distinct
      Rails.logger.info "Available services after travel patterns: #{@available_services}"
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
    Rails.logger.info("[TripPlanner#build_all_itineraries] Building for types: #{@trip_types.inspect}")
  
    trip_itineraries = @trip_types.flat_map do |t|
      Rails.logger.info("[TripPlanner#build_all_itineraries] → Building for trip_type: #{t}")
      build_itineraries(t)
    end
  
    trip_itineraries.each_with_index do |itin, idx|
      leg_modes = itin.legs&.map { |l| l['mode'] } || []
      Rails.logger.info("[TripPlanner#build_all_itineraries] Raw Itinerary ##{idx} modes: #{leg_modes}, initial type: #{itin.trip_type}")
    end
  
    # Reclassification
    trip_itineraries.each_with_index do |itin, idx|
      if itin.legs&.any?
        modes = itin.legs.map { |leg| leg["mode"] }
        has_flex = modes.include?("FLEX_ACCESS")
        has_walk = modes.include?("WALK")
        has_transit = modes.include?("BUS")
        all_walk = modes.all? { |m| m == "WALK" }
  
        Rails.logger.info("[TripPlanner#build_all_itineraries] Itin ##{idx} pre-reclass: #{modes} type=#{itin.trip_type}")
  
        if has_flex && has_walk && has_transit
          itin.trip_type = "paratransit_mixed"
          Rails.logger.info("[TripPlanner#build_all_itineraries] → Reclassed as paratransit_mixed (has FLEX, WALK, BUS)")
        elsif has_flex && has_walk
          itin.trip_type = "paratransit_mixed"
          Rails.logger.info("[TripPlanner#build_all_itineraries] → Reclassed as paratransit_mixed (has FLEX + WALK)")
        elsif all_walk
          itin.trip_type = "walk"
          Rails.logger.info("[TripPlanner#build_all_itineraries] → Reclassed as walk")
        end
      end
    end
  
    @trip.itineraries += trip_itineraries.reject(&:persisted?)
  end
  
  

  # Additional sanity checks can be applied here.
  def filter_itineraries
    Rails.logger.info("[TripPlanner#filter_itineraries] Filtering trip #{@trip.id} — initial: #{@trip.itineraries.size}")
    walk_seen = false
  
    @trip.itineraries.each_with_index do |itin, idx|
      Rails.logger.info("[TripPlanner#filter_itineraries] Itinerary ##{idx} trip_type=#{itin.trip_type}")
      itin.legs&.each_with_index do |leg, i|
        Rails.logger.info("  └── Leg #{i}: mode=#{leg['mode']}, serviceType=#{leg['serviceType']}")
      end
    end
  
    @trip.itineraries = @trip.itineraries.compact
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
    itineraries = build_fixed_itineraries(:transit)
    unless @trip_types.include?(:walk)
      itineraries.reject! { |itin| itin.legs.all? { |leg| leg["mode"] == "WALK" } }
    end
    
    itineraries

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
    Rails.logger.info("[TripPlanner#build_paratransit_itineraries] Starting...")
  
    otp_itineraries = build_fixed_itineraries(:paratransit)
    Rails.logger.info("[TripPlanner#build_paratransit_itineraries] OTP itineraries returned: #{otp_itineraries.size}")
  
    otp_itineraries.each_with_index do |itin, idx|
      leg_modes = itin.legs.map { |leg| leg["mode"] }
      Rails.logger.info("[TripPlanner#build_paratransit_itineraries] OTP Itinerary ##{idx} modes: #{leg_modes}")
    end
  
    router_itineraries = otp_itineraries.map.with_index do |itin, idx|
      itinerary = Itinerary.find_or_initialize_by(service_id: itin.service_id, trip_type: :paratransit, trip_id: @trip.id)
      itinerary.legs = itin.legs
  
      modes = itin.legs.map { |l| l["mode"] }
      Rails.logger.info("[TripPlanner#build_paratransit_itineraries] Rechecking Itin ##{idx} modes: #{modes}")
  
      if modes.include?("FLEX_ACCESS") && modes.include?("WALK") && modes.any? { |m| !["WALK", "FLEX_ACCESS"].include?(m) }
        itinerary.trip_type = "paratransit_mixed"
        Rails.logger.info("[TripPlanner#build_paratransit_itineraries] → Marked as paratransit_mixed")
      elsif modes.include?("FLEX_ACCESS") && modes.include?("WALK")
        itinerary.trip_type = "paratransit"
        Rails.logger.info("[TripPlanner#build_paratransit_itineraries] → Marked as paratransit")
      else
        Rails.logger.info("[TripPlanner#build_paratransit_itineraries] → Keeping default trip_type=#{itinerary.trip_type}")
      end
  
      itinerary
    end
  
    Rails.logger.info("[TripPlanner#build_paratransit_itineraries] Final router itineraries: #{router_itineraries.size}")
    router_itineraries
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