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
    Rails.logger.info("Plan: Starting plan for trip: #{@trip.id}")
    set_available_services
    prepare_ambassadors
    Rails.logger.info("Plan: Trip types: #{@trip_types.inspect}")
    Rails.logger.info("Plan: Available services: #{@available_services.inspect}")
    build_all_itineraries
    Rails.logger.info("Plan: Itineraries after build:")
    @trip.itineraries.each do |itin|
      Rails.logger.info("Plan: Itinerary trip_type=#{itin.trip_type}, service_id=#{itin.service_id}")
      if itin.legs.present?
        itin.legs.each { |leg| Rails.logger.info("Plan: Leg mode=#{leg['mode']}, serviceType=#{leg['serviceType']}") }
      else
        Rails.logger.warn("Plan: Itinerary has no legs: #{itin.inspect}")
      end
    end
    filter_itineraries
    @trip.save
    Rails.logger.info("Plan: Trip saved with #{@trip.itineraries.size} itineraries")
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
    Rails.logger.info("build_all_itineraries: Building itineraries for trip types: #{@trip_types.inspect}")
    @trip_types.each { |t| Rails.logger.info("build_all_itineraries: Processing trip type: #{t}") }
    trip_itineraries = @trip_types.flat_map do |t|
      Rails.logger.info("build_all_itineraries: Calling build_itineraries for trip type: #{t}")
      build_itineraries(t)
    end
  
    Rails.logger.info("build_all_itineraries: Reclassifying itineraries based on legs")
    trip_itineraries.each do |itin|
      if itin.legs&.any?
        all_walk   = itin.legs.all? { |leg| leg["mode"] == "WALK" }
        has_walk   = itin.legs.any? { |leg| leg["mode"] == "WALK" }
        has_transit = itin.legs.any? { |leg| leg["mode"] == "BUS" }
        has_flex   = itin.legs.any? { |leg| leg["mode"] == "FLEX_ACCESS" }
        has_car_park = itin.legs.any? { |leg| leg["mode"] == "CAR_PARK" }
        Rails.logger.info("build_all_itineraries: Pre-reclassify itinerary #{itin.inspect}")
  
        if has_flex && has_walk && has_transit
          Rails.logger.info("build_all_itineraries: Reclassifying itinerary with FLEX_ACCESS, WALK, and BUS—setting trip type to paratransit_mixed")
          itin.trip_type = "paratransit_mixed"
        elsif has_flex && has_walk
          Rails.logger.info("build_all_itineraries: Reclassifying itinerary with FLEX_ACCESS and WALK—setting trip type to paratransit_mixed")
          itin.trip_type = "paratransit_mixed"
        elsif has_walk && itin.trip_type == "paratransit"
          Rails.logger.info("build_all_itineraries: Reclassifying walk-only itinerary as paratransit.")
          itin.trip_type = "paratransit"
        elsif has_transit && itin.trip_type == "walk"
          Rails.logger.info("build_all_itineraries: Reclassifying walk-only itinerary as transit.")
          itin.trip_type = "transit"
        elsif all_walk && itin.trip_type == "transit"
          Rails.logger.info("build_all_itineraries: Reclassifying walk-only itinerary as walk.")
          itin.trip_type = "walk"
        end
      else
        Rails.logger.warn("build_all_itineraries: Skipping reclassification for itinerary with no legs: #{itin.inspect}")
      end
    end
  
    new_itineraries = trip_itineraries.reject(&:persisted?)
    old_itineraries = trip_itineraries.select(&:persisted?)
    Rails.logger.info("build_all_itineraries: New itineraries count: #{new_itineraries.count}")
    Rails.logger.info("build_all_itineraries: Old itineraries count: #{old_itineraries.count}")
  
    Itinerary.transaction do
      old_itineraries.each do |itin|
        Rails.logger.info("build_all_itineraries: Saving existing itinerary: #{itin.inspect}")
        itin.save!
      end
      @trip.itineraries += new_itineraries
    end
  
    Rails.logger.info("build_all_itineraries: All itineraries successfully processed for trip: #{@trip.id}")
  end

  # Additional sanity checks can be applied here.
  def filter_itineraries
    Rails.logger.info("filter_itineraries: Filtering itineraries for trip #{@trip.id}. Initial count: #{@trip.itineraries.count}")
    walk_seen = false
    itineraries = @trip.itineraries.map do |itin|
      Rails.logger.info("filter_itineraries: Evaluating itinerary: #{itin.inspect}")
  
      # Test: Make sure we never exceed the maximum walk time
      if itin.walk_time && itin.walk_time > max_walk_minutes * 60
        Rails.logger.info("filter_itineraries: Excluding itinerary due to excessive walk_time: #{itin.walk_time}")
        next
      end
  
      # Test: Make sure that we only ever return 1 walk trip
      if itin.walk_time && itin.duration && itin.walk_time == itin.duration
        if walk_seen
          Rails.logger.info("filter_itineraries: Excluding duplicate walk-only itinerary")
          next
        else
          walk_seen = true
        end
      end
  
      # Test: Filter out walk-only itineraries when walking is deselected
      if !@trip.itineraries.map(&:trip_type).include?('walk') && itin.trip_type == 'transit' && 
         itin.legs.all? { |leg| leg['mode'] == 'WALK' } && itin.walk_distance >= itin.legs.first['distance']
        Rails.logger.info("filter_itineraries: Excluding transit itinerary that's walk-only (deselected walking)")
        next
      end
  
      # Test: Filter out itineraries where a walking leg exceeds maximum distance
      if !@trip.itineraries.map(&:trip_type).include?('walk') && itin.trip_type == 'transit' &&
         itin.legs.detect { |leg| leg['mode'] == 'WALK' && leg["distance"] > max_walk_distance }
        Rails.logger.info("filter_itineraries: Excluding transit itinerary due to a walking leg exceeding max_walk_distance")
        next
      end
  
      # Only apply max_walk_distance if walking is not selected as a trip type
      if !@trip.itineraries.map(&:trip_type).include?('walk')
        if itin.trip_type == 'transit' && itin.legs.any? { |leg| leg['mode'] == 'WALK' && leg["distance"] > max_walk_distance }
          Rails.logger.info("filter_itineraries: Excluding transit itinerary due to max_walk_distance")
          next
        end
      end
  
      # Reclassification logic based on itinerary legs
      if itin.legs&.any?
        all_walk = itin.legs.all? { |leg| leg["mode"] == "WALK" }
        has_walk = itin.legs.any? { |leg| leg["mode"] == "WALK" }
        has_transit = itin.legs.any? { |leg| leg["mode"] == "BUS" }
        has_flex = itin.legs.any? { |leg| leg["mode"] == "FLEX_ACCESS" }
        has_car_park = itin.legs.any? { |leg| leg["mode"] == "CAR_PARK" }
        
        if (has_walk && itin.legs.any? { |leg| leg["mode"] == "FLEX_ACCESS" }) &&
           itin.legs.any? { |leg| !["WALK", "FLEX_ACCESS"].include?(leg["mode"]) }
          Rails.logger.info("filter_itineraries: Reclassifying itinerary as paratransit_mixed")
          itin.trip_type = "paratransit_mixed"
        elsif has_flex && has_walk
          Rails.logger.info("filter_itineraries: Reclassifying itinerary as paratransit")
          itin.trip_type = "paratransit"
        elsif has_walk && itin.trip_type == "paratransit"
          Rails.logger.info("filter_itineraries: Reclassifying walk-only itinerary as paratransit")
          itin.trip_type = "paratransit"
        elsif has_transit && itin.trip_type == "walk"
          Rails.logger.info("filter_itineraries: Reclassifying itinerary as transit")
          itin.trip_type = "transit"
        elsif all_walk && itin.trip_type == "transit"
          Rails.logger.info("filter_itineraries: Reclassifying itinerary as walk")
          itin.trip_type = "walk"
        end
      else
        Rails.logger.warn("filter_itineraries: Skipping reclassification for itinerary with no legs: #{itin.inspect}")
      end
  
      itin 
    end
    itineraries.delete(nil)
    @trip.itineraries = itineraries
    Rails.logger.info("filter_itineraries: Final itineraries count: #{@trip.itineraries.count}")
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
    Rails.logger.info("build_paratransit_itineraries: Starting...")
    return [] unless @available_services[:paratransit].present?
  
    otp_itineraries = build_fixed_itineraries(:paratransit).select { |itin| itin.service_id.present? && itin.service.type == 'Paratransit' }
    Rails.logger.info("build_paratransit_itineraries: OTP itineraries count: #{otp_itineraries.size}")
    Rails.logger.info("build_paratransit_itineraries: OTP itineraries: #{otp_itineraries.inspect}")
  
    otp_itineraries.reject! do |itin|
      has_paratransit = itin.legs.any? { |leg| leg["serviceType"] == "Paratransit" }
      has_transit = itin.legs.any? { |leg| leg["serviceType"] == "Transit" }
      result = (!has_paratransit && has_transit)
      Rails.logger.info("build_paratransit_itineraries: Evaluating itinerary #{itin.inspect} for rejection: #{result}")
      result
    end
  
    router_itineraries = otp_itineraries.map do |itin|
      itinerary = Itinerary.left_joins(:booking)
                            .where(bookings: { id: nil })
                            .find_or_initialize_by(
                              service_id: itin.service_id,
                              trip_type: :paratransit,
                              trip_id: @trip.id
                            )
  
      duration = itin["duration"] || (itin.legs&.first && itin.legs&.last ? 
                  (itin.legs.last["to"]["arrivalTime"] - itin.legs.first["from"]["departureTime"]) / 1000.0 : 0)
      calculated_duration = duration * @paratransit_drive_time_multiplier
  
      itinerary.assign_attributes({
        assistant: @options[:assistant],
        companions: @options[:companions],
        cost: itin.service.fare_for(@trip, router: @router, companions: @options[:companions], assistant: @options[:assistant]),
        transit_time: calculated_duration,
        legs: itin.legs
      })
  
      has_flex = itinerary.legs.any? { |leg| leg["mode"] == "FLEX_ACCESS" }
      has_walk = itinerary.legs.any? { |leg| leg["mode"] == "WALK" }
      has_other_mode = itinerary.legs.any? { |leg| !["FLEX_ACCESS", "WALK"].include?(leg["mode"]) }
  
      Rails.logger.info("build_paratransit_itineraries: Processing itinerary for service_id #{itin.service_id} with leg modes: #{itinerary.legs.map { |l| l['mode'] }.inspect}")
  
      if has_flex && has_walk && has_other_mode
        itinerary.trip_type = "paratransit_mixed"
        Rails.logger.info("build_paratransit_itineraries: Marked as paratransit_mixed (has FLEX_ACCESS, WALK, and another mode)")
      elsif has_flex && has_walk
        itinerary.trip_type = "paratransit"
        Rails.logger.info("build_paratransit_itineraries: Marked as paratransit (has only FLEX_ACCESS and WALK)")
      end
  
      itinerary
    end
  
    non_gtfs_services = @available_services[:paratransit].where(gtfs_agency_id: [nil, ""])
    non_gtfs_itineraries = non_gtfs_services.map do |svc|
      Rails.logger.info("build_paratransit_itineraries: Processing non-GTFS service ID: #{svc.id}")
      itinerary = Itinerary.left_joins(:booking)
                            .where(bookings: { id: nil })
                            .find_or_initialize_by(
                              service_id: svc.id,
                              trip_type: :paratransit,
                              trip_id: @trip.id
                            )
      duration = @router.get_duration(:paratransit) || 0
      calculated_duration = duration * @paratransit_drive_time_multiplier
      itinerary.assign_attributes({
        assistant: @options[:assistant],
        companions: @options[:companions],
        cost: svc.fare_for(@trip, router: @router, companions: @options[:companions], assistant: @options[:assistant]),
        transit_time: calculated_duration,
      })
      itinerary
    end
  
    all_itineraries = (router_itineraries + non_gtfs_itineraries).compact
    Rails.logger.info("build_paratransit_itineraries: Final built itineraries count: #{all_itineraries.count}")
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