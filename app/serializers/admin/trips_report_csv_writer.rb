module Admin
  class TripsReportCSVWriter < CSVWriter

    columns :trip_id, :trip_time, :traveler, :user_type, :traveler_county, :traveler_paratransit_id, :arrive_by,
            :disposition_status, :purpose, :orig_addr, :orig_county, :orig_lat, :orig_lng, :dest_addr, :dest_county,
            :dest_lat, :dest_lng, :traveler_age, :traveler_ip, :traveler_accommodations, :traveler_eligibilities,
            :agency_name, :service_name, :booking_id, :booking_client_id, :is_round_trip, :booking_timestamp,
            :funding_source, :sponsor, :companions, :trip_note, :ecolane_error_message, :pca
    associations :origin, :destination, :user, :selected_itinerary

    FMR_COLUMNS = [
      :trip_time, :traveler, :arrive_by, :disposition_status, :purpose, :orig_addr, :orig_lat, :orig_lng,
      :dest_addr, :dest_lat, :dest_lng, :agency_name, :service_name, :booking_id, :booking_client_id, :is_round_trip,
      :booking_timestamp, :funding_source, :sponsor, :companions, :trip_note, :ecolane_error_message, :pca
    ]

    def self.in_travel_patterns_mode?
      Config.dashboard_mode.to_sym == :travel_patterns
    end

    def headers
      if self.class.in_travel_patterns_mode?
        # Only include FMR_COLUMNS if in travel patterns mode
        self.class.headers.slice(*FMR_COLUMNS)
      else
        self.class.headers
      end
    end

    # Helper method to access booking snapshot
    def booking_snapshot
      @record.booking&.ecolane_booking_snapshot
    end

    def trip_id
      @record.id
    end

    def purpose
      if @record.booking.ecolane_booking_snapshot&.purpose
        @record.booking.ecolane_booking_snapshot.purpose
      elsif @record.external_purpose
        @record.external_purpose
      elsif @record.purpose
        @record.purpose.code
      else
        "N/A"
      end
    end
    

    def trip_time
      booking_snapshot&.negotiated_pu || @record.trip_time&.in_time_zone
    end

    def traveler
      booking_snapshot&.traveler || @record.user&.email
    end

    def user_type
      if @record.user&.admin_or_staff?
        'Staff User'
      elsif @record.user&.guest?
        I18n.t('admin.reporting.guest') || 'Guest'
      elsif @record.user&.registered_traveler?
        I18n.t('admin.reporting.public_user') || 'Public User'
      else
        ''
      end
    end

    def traveler_county
      @record.user&.county
    end

    def traveler_paratransit_id
      @record.user&.paratransit_id
    end

    def agency_name
      booking_snapshot&.agency_name || @record.user.booking_profile.service.agency.name rescue 'No Agency'
    end

    def service_name
      booking_snapshot&.service_name || @record.user.booking_profile.service.name rescue 'No Service'
    end

    def booking_id
      booking_snapshot&.confirmation || @record.booking&.confirmation || 'No Booking ID'
    end

    def booking_client_id
      booking_snapshot&.booking_client_id || @record.booking&.details&.dig(:client_id) || 'No Client ID'
    end

    def booking_timestamp
      booking_snapshot&.created_at&.strftime("%Y-%m-%d %H:%M:%S") || @record.booking&.created_at&.strftime("%Y-%m-%d %H:%M:%S") || 'No Booking Timestamp'
    end

    def funding_source
      booking_snapshot&.funding_source || @record.booking&.details&.dig(:funding_hash, :funding_source) || 'No Funding Source'
    end

    def sponsor
      booking_snapshot&.sponsor || @record.booking&.details&.dig(:funding_hash, :sponsor) || 'No Sponsor'
    end

    def companions
      booking_snapshot&.companions || @record.booking&.itinerary&.companions || '0'
    end

    def trip_note
      booking_snapshot&.note || @record.booking&.itinerary&.note || ' '
    end

    def ecolane_error_message
      booking_snapshot&.ecolane_error_message || @record.selected_itinerary&.booking&.ecolane_error_message || 'N/A'
    end

    def pca
      booking_snapshot&.pca || (@record.selected_itinerary&.assistant ? 'TRUE' : 'FALSE')
    end

    def disposition_status
      booking_snapshot&.status || @record.disposition_status || Trip::DISPOSITION_STATUSES[:unknown]
    end

    def orig_addr
      booking_snapshot&.orig_addr || @record.origin&.formatted_address
    end

    def orig_county
      @record.origin&.county
    end

    def orig_lat
      booking_snapshot&.orig_lat || @record.origin&.lat
    end

    def orig_lng
      booking_snapshot&.orig_lng || @record.origin&.lng
    end

    def dest_addr
      booking_snapshot&.dest_addr || @record.destination&.formatted_address
    end

    def dest_county
      @record.destination&.county
    end

    def dest_lat
      booking_snapshot&.dest_lat || @record.destination&.lat
    end

    def dest_lng
      booking_snapshot&.dest_lng || @record.destination&.lng
    end

    def traveler_age
      @record.user_age
    end

    def traveler_ip
      @record.user_ip
    end

    def traveler_accommodations
      @record.trip_accommodations.reduce('') { |string, acc_hash| "#{string}#{acc_hash&.accommodation&.code}; " }
    end

    def traveler_eligibilities
      @record.trip_eligibilities.reduce('') { |string, elg_hash| "#{string}#{elg_hash&.eligibility&.code}; " }
    end

    def is_round_trip
      if @record.booking.ecolane_booking_snapshot&.is_round_trip
        @record.booking.ecolane_booking_snapshot.is_round_trip ? 'TRUE' : 'FALSE'
      elsif @record.previous_trip_id.present?
        'TRUE'
      else
        'FALSE'
      end
    end    
    

  end
end
