module Api
  module V2
    class ServiceSerializer < ApiSerializer

      attributes :id, :name, :type, :logo, :full_logo, :url, :email, :phone, :formatted_phone,
                 :description, :rating, :ratings_count, :fare_text
                 
      has_many :schedules
      has_many :accommodations
      has_many :eligibilities
      has_many :purposes
      
      def description
        object.description(locale)
      end
      
      def schedules
        object.schedules.for_display
      end
      
      def logo
        object.full_logo_url
      end

      def full_logo
        object.full_logo_url(nil) # get actual size
      end

      def fare_text
        object.fare_text(locale)
      end
    end
  end
end
