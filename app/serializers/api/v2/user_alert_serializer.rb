module Api
  module V2
    class UserAlertSerializer < ApiSerializer
		  
		  attributes :id, :subject, :message
      
      def subject
        object.try(:subject, locale)
      end
      
      def message
        object.try(:message, locale)
      end

      def id
        object.try(:alert_id)
      end
    
    end
  end
end
