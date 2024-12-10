# require 'json'
# require 'net/http'
# require 'eventmachine' # For multi_plan
# require 'em-http' # For multi_plan

# Namespaced module for containing helper classes for interacting with OTP via rails.
# Doesn't know about 1-Click models, controllers, etc.
module OTP

  class OTPService
    attr_accessor :base_url
    attr_accessor :version

    def initialize(base_url="", version="v1")
      @base_url = base_url
      @version = version
    end

    # Makes multiple OTP requests in parallel, and returns once they're all done.
    # Send it a list or array of request hashes.
    def multi_plan(*requests)
      requests = requests.flatten.uniq { |req| req[:label] } # Discard duplicate labels
    
      bundler = HTTPRequestBundler.new
    
      # Add all requests to the bundler, iterating over request types
      requests.each_with_index do |request, i|
        request_types = determine_request_types(request[:options]) # Existing logic for determining trip types
    
        request_types.each do |type, type_options|
          transport_modes = type_options[:modes] # Modes for this trip type
          body = build_graphql_body(
            request[:from],
            request[:to],
            request[:trip_time],
            transport_modes
          )
          url = "#{@base_url}/otp/routers/default/index/graphql"
    
          label = "#{request[:label] || "req#{i}"}_#{type}".to_sym
          bundler.add(label, url, :post, head: { 'Content-Type' => 'application/json' }, body: body.to_json)
        end
      end
    
      bundler.make_calls
    
      # Return the parsed responses
      bundler.responses
    end
    
    def plan(from, to, trip_datetime, arrive_by = true, transport_modes = nil, options = {})
      # Default modes based on options or transport_modes
      transport_modes ||= determine_default_modes(options) # Logic to get default modes

      # GraphQL endpoint
      url = "#{@base_url}/index/graphql"

      Rails.logger.info("OTP Request: #{from} to #{to} at #{trip_datetime} with modes #{transport_modes}")
      Rails.logger.info("Url: #{url}")

      # Build GraphQL body
      body = build_graphql_body(from, to, trip_datetime, transport_modes)
      
      headers = {
        'Content-Type' => 'application/json',
        'x-user-email' => '1-click@camsys.com',
        'x-user-token' => 'sRRTZ3BV3tmms1o4QNk2'
      }

      # Use HTTPRequestBundler for a single request
      bundler = HTTPRequestBundler.new
      bundler.add(:plan_request, url, :post, head: headers, body: body.to_json)
      Rails.logger.info("GraphQL Request: #{body}")
      Rails.logger.info("GraphQL URL: #{url}")
      Rails.logger.info("GraphQL Headers: #{headers}")
      bundler.make_calls

      # Process and parse the response
      response = bundler.response(:plan_request)

      response    
    end

    def determine_request_types(options = {})
      {
        transit: { modes: [{ mode: "TRANSIT" }] },
        walk: { modes: [{ mode: "WALK" }] },
        flex: { modes: [{ mode: "FLEX", qualifier: "DIRECT" }] }
      }.select do |type, _|
        options[:allow_flex] || type != :flex
      end
    end  

    def build_graphql_body(from, to, trip_datetime, transport_modes, options = {})
      arrive_by = options[:arrive_by].nil? ? true : options[:arrive_by]
      walk_speed = options[:walk_speed] || 3.0 # in m/s
      max_walk_distance = options[:max_walk_distance] || 2 * 1609.34 # in meters
      max_bicycle_distance = options[:max_bicycle_distance] || 5 * 1609.34 # in meters
      walk_reluctance = options[:walk_reluctance] || Config.walk_reluctance
      bike_reluctance = options[:bike_reluctance] || Config.bike_reluctance

      # Determine number of itineraries for the transport mode
      num_itineraries = transport_modes.map do |mode|
        case mode[:mode]
        when "TRANSIT"
          Config.otp_transit_quantity
        when "FLEX"
          Config.otp_paratransit_quantity
        when "BICYCLE"
          Config.otp_bike_quantity
        when "WALK"
          Config.otp_walk_quantity
        else
          Config.otp_itinerary_quantity
        end
      end.first || Config.otp_itinerary_quantity
    
      # Format transport modes for GraphQL
      formatted_modes = transport_modes.map do |mode|
        if mode[:mode] == "FLEX"
          "{ mode: #{mode[:mode]}, qualifier: #{mode[:qualifier]} }"
        else
          "{ mode: #{mode[:mode]} }"
        end
      end.join(", ")
    
      # Build GraphQL query
      {
        query: <<-GRAPHQL,
          query($fromLat: Float!, $fromLon: Float!, $toLat: Float!, $toLon: Float!, $date: String!, $time: String!) {
            plan(
              from: { lat: $fromLat, lon: $fromLon }
              to: { lat: $toLat, lon: $toLon }
              date: $date
              time: $time
              transportModes: [#{formatted_modes}]
              numItineraries: #{num_itineraries}
              walkSpeed: #{walk_speed}
              maxWalkDistance: #{max_walk_distance}
              walkReluctance: #{walk_reluctance}
              bikeReluctance: #{bike_reluctance}
            ) {
              itineraries {
                startTime
                endTime
                duration
                walkTime
                waitingTime
                walkDistance
                fares {
                  type
                  cents
                  currency
                  components {
                    fareId
                    currency
                    cents
                    routes {
                      gtfsId
                      shortName
                    }
                  }
                }
                legs {
                  mode
                  distance
                  route { 
                    gtfsId
                    shortName
                    longName
                    agency {
                      gtfsId
                      name
                    }
                  }
                  from {
                    name
                    lat
                    lon
                    departureTime
                  }
                  to {
                    name
                    lat
                    lon
                    arrivalTime
                  }
                  fareProducts {
                    id
                    product {
                      name
                      ... on DefaultFareProduct {
                        price {
                          amount
                          currency {
                            code
                            digits
                          }
                        }
                      }
                      riderCategory {
                        name
                      }
                    }
                  }
                }
              }
            }
          }
        GRAPHQL
        variables: {
          fromLat: from[0].to_f,
          fromLon: from[1].to_f,
          toLat: to[0].to_f,
          toLon: to[1].to_f,
          date: trip_datetime.strftime("%Y-%m-%d"),
          time: trip_datetime.strftime("%H:%M")
        }
      }
    end

    # Wraps a response body in an OTPResponse object for easy inspection and manipulation
    def unpack(response)
      return OTPResponse.new(response)
    end

  end

  # Wrapper class for OTP Responses
  class OTPResponse
    attr_accessor :response, :itineraries

    # Pass a response body hash (e.g. parsed JSON) to initialize
    def initialize(response)
      response = JSON.parse(response) if response.is_a?(String)
      @response = response.with_indifferent_access
      @itineraries = extract_itineraries
    end

    # Allows you to access the response with [key] method
    # first converts key to lowerCamelCase
    def [](key)
      @response[key.to_s.camelcase(:lower)]
    end

    # Returns the array of itineraries
    def extract_itineraries
      # Use dig to safely navigate the response
      itineraries = @response.dig('data', 'plan', 'itineraries')
      
      # Log the extracted itineraries for debugging
      
      # Return an empty array if itineraries are nil or not an array
      return [] unless itineraries.is_a?(Array)
      
      # Parse each itinerary and initialize it as an OTPItinerary object
      itineraries.map { |i| OTPItinerary.new(i) }
    rescue => e
      Rails.logger.error("Error in extract_itineraries: #{e.message}")
      []
    end

  end


  # Wrapper class for OTP Itineraries
  class OTPItinerary
    attr_accessor :itinerary

    # Pass an OTP itinerary hash (e.g. parsed JSON) to initialize
    def initialize(itinerary)
      itinerary = JSON.parse(itinerary) if itinerary.is_a?(String)
      @itinerary = itinerary.with_indifferent_access
    end

    # Allows you to access the itinerary with [key] method
    # first converts key to lowerCamelCase
    def [](key)
      @itinerary[key.to_s.camelcase(:lower)]
    end

    # Extracts the fare value in dollars
    def fare_in_dollars
      @itinerary['fare'] &&
      @itinerary['fare']['fare'] &&
      @itinerary['fare']['fare']['regular'] &&
      @itinerary['fare']['fare']['regular']['cents'].to_f/100.0
    end

    # Getter method for itinerary's legs
    def legs
      OTPLegs.new(@itinerary['legs'] || [])
    end

    # Setter method for itinerary's legs
    def legs=(new_legs)
      @itinerary['legs'] = new_legs.try(:to_a)
    end
    
  end


  # Wrapper class for OTP Legs array, providing helper methods
  class OTPLegs
    attr_reader :legs
    
    # Pass an OTP legs array (e.g. parsed or un-parsed JSON) to initialize
    def initialize(legs)
      
      # Parse the legs array if it's a JSON string
      legs = JSON.parse(legs) if legs.is_a?(String)
      
      # Make the legs array an array of hashes with indifferent access
      @legs = legs.map { |l| l.try(:with_indifferent_access) }.compact
    end
    
    # Return legs array on to_a
    def to_a
      @legs
    end
    
    # Pass to_s method along to legs array
    def to_s
      @legs.to_s
    end
    
    # Pass map method along to legs array
    def map &block
      @legs.map &block
    end
    
    # Pass each method along to legs array
    def each &block
      @legs.each &block
    end
    
    # Returns first instance of an attribute from the legs
    def detect &block
      @legs.detect &block
    end
    
    # Returns an array of all non-nil instances of the given value in the legs
    def pluck(attribute)
      @legs.pluck(attribute).compact
    end
    
    # Sums up an attribute across all legs, ignoring nil and non-numeric values
    def sum_by(attribute)
      @legs.pluck(attribute).select{|i| i.is_a?(Numeric)}.reduce(&:+)
    end
  
  end

end
