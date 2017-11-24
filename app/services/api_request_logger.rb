# Service object for Logging requests made to API Controllers
class ApiRequestLogger
  
  attr_accessor :root_path, :exclude_controllers, :exclude_actions

  # Initialize with a root_path string, e.g. "/", "/api", "/api/v2"...
  # Also accepts an options hash to configure which actions to log:
  #  * exclude_controllers: Pass an array of controller name strings/substrings.
  #    Will not log requests to any of those controllers.
  #  * exclude_actions: Pass a hash with keys that are controller names, and 
  #    values that are arrays of action names to be excluded for that controller.
  def initialize(root_path, opts={})
    @root_path = root_path
    configure(opts)
  end
  
  # By default, only log requests for Api-namespaced controllers.
  # Do not exclude any controllers or controller actions.
  def configure(opts={})
    @exclude_controllers = opts[:exclude_controllers] || []
    @exclude_actions = Hash.new([]).merge(opts[:exclude_actions] || {})
    return self
  end
  
  # Start logging requests
  def start
    # Subscribes to an event that occurs whenever a controller request is made
    ActiveSupport::Notifications.subscribe 'process_action.action_controller' do |*args|
      event = ActiveSupport::Notifications::Event.new(*args)
      payload = event.payload
      
      # The controller and action are included and not excluded, create a 
      # RequestLog object for the request.
      if should_log?(payload)
        RequestLog.create({
          controller: payload[:controller],
          action: payload[:action],
          params: payload[:params],
          status_code: payload[:status],
          auth_email: payload[:headers]["X-User-Email"],
          duration: event.duration.to_i
        })
      end
      
    end
  end

  # Stop logging requests
  def stop
    ActiveSupport::Notifications.unsubscribe 'process_action.action_controller'
  end

  # Pass it the event payload. Will determine whether or not to log request
  # based on:
  #  * If the start of the request path matches the mount path
  #  * The controller matches any excluded controllers
  #  * The controller & action match any excluded controller/action pairs
  def should_log?(payload)
    payload[:path].index(@root_path) == 0 &&
    @exclude_controllers.none? { |ctrl| payload[:controller].include?(ctrl) } &&
    @exclude_actions[payload[:controller]].exclude?(payload[:action])
  end
  
end
