namespace :ecolane do
  desc "Update Ecolane POIs"
  task :update_pois => :environment do
    # Check to see if another instance is already running
    is_already_running = false
    task_run_state = Config.find_or_create_by key: 'ecolane_task_is_running'
    task_run_state.with_lock do
      task_run_state.reload
      is_already_running = task_run_state.value
      # Make sure this isn't an old value that didn't get cleaned up
      if is_already_running && task_run_state.updated_at > (DateTime.now - 1.day)
        puts "Another task instance is already running. Exiting."
        exit
      else
        task_run_state.value = true
        task_run_state.save!
        puts "Running this instance."
      end
    end

    messages = []
    local_error = false

    # Ecolane POIs are broken down by system. First, get a list of all the unique Ecolane Systems.
    # Order from oldest to newest.
    systems = []
    services_by_system = Hash.new { |hash, key| hash[key] = [] }

    Service.paratransit_services.published.is_ecolane.order(:id).each do |service|
      next if service.booking_details[:external_id].blank? || service.booking_details[:token].blank? || service.agency.blank?

      systems << service.booking_details[:external_id] unless systems.include?(service.booking_details[:external_id])
      services_by_system[service.booking_details[:external_id]] << service

      puts "Preparing to sync System: #{service.booking_details[:external_id]}, Service: #{service.id} #{service.name}, Agency: #{service&.agency&.id}"
    end

    puts "starting sync"
    # Get the current POIs and mark them as old
    Landmark.update_all(old: true)
    poi_processed_count = 0
    poi_with_no_city = 0
    poi_blank_name_count = 0
    poi_total_duplicate_count = 0

    systems.each do |system|
      services = services_by_system[system]
      services.each do |service|
        local_error = false
        agency_id = service&.agency&.id
        service_id = service.id

        begin
          # Get a Hash of new POIs from Ecolane for the service
          new_poi_hashes = service.booking_ambassador.get_pois
          if new_poi_hashes.nil?
            # If anything goes wrong the new pois will be deleted and the old reinstated
            messages << "Error loading POIs for System: #{system}, service_id: #{service.id}. Unable to retrieve POIs"
            local_error = true
            puts messages.to_s
            next
          end

          puts "Processing #{new_poi_hashes.count} POIs for #{system}, Service: #{service.id} #{service.name}"
          new_poi_duplicate_count = 0
          # Import named pois before unnamed locations
          new_poi_hashes_sorted = new_poi_hashes.sort_by { |h| h[:name].blank? ? 'ZZZZZ' : h[:name] }

          new_poi_hashes_sorted.each do |hash|
            # Check for exact duplicates considering name, address, and city
            existing_poi = Landmark.where(
              name: hash[:name], 
              street_number: hash[:street_number], 
              route: hash[:route], 
              city: hash[:city]
            ).first

            if existing_poi
              # If the landmark already exists, just associate it with the current services
              existing_poi.services << service unless existing_poi.services.include?(service)
              new_poi_duplicate_count += 1
              existing_poi.update(old: false)
              next
            end

            new_poi = Landmark.new(hash)
            new_poi.old = false
            new_poi.agency_id = agency_id

            if new_poi.city.blank?
              puts 'CITYLESS POI, EXCLUDING FROM WAYPOINTS'
              puts hash.ai
              poi_with_no_city += 1
              next
            end

            # Skip POIs whose names contain "do not use" case insensitive
            next if new_poi.name =~ /do not use/i

            # All POIs need a name. If Ecolane doesn't define one, then name it after the Address
            if new_poi.name.blank?
              new_poi.name = new_poi.auto_name
              poi_blank_name_count += 1
              new_poi.search_text = ''
            else
              new_poi.search_text = "#{new_poi.name} "
            end

            # Use the name + address to determine duplicates
            new_poi.search_text += "#{new_poi.auto_name}"
            if new_poi_names_set.add?(new_poi.search_text.strip.downcase).nil?
              new_poi_duplicate_count += 1
              puts "Duplicate found: #{new_poi.search_text}"
              next
            end

            new_poi.search_text += " #{new_poi.zip}"

            # HACK: Because of FMRPA-153 we need to support duplicate names.
            # Rather than change the model validation for all of 1-Click, just override it here for FMR.
            if !new_poi.save(validate: false)
              puts "Save failed for POI with errors #{new_poi.errors.full_messages}"
              puts "#{new_poi}"
            end
          end

        rescue Exception => e
          # If anything goes wrong....
          messages << "Error loading POIs for #{system}. #{e.message}."
          local_error = true
          # Log if errors happen
          puts messages.to_s
          break
        end

        unless local_error
          #If we made it this far, then we have a new set of POIs and we can delete the old ones.
          new_poi_count = new_poi_hashes.count
          messages << "Successfully loaded  #{new_poi_count} POIs with #{new_poi_duplicate_count} duplicates for #{system}."
          poi_total_duplicate_count += new_poi_duplicate_count
        end

        rescue Exception => e
          messages << "Error loading POIs for #{system}, Service: #{service.id} #{service.name}. #{e.message}."
          local_error = true
          # Log if errors happen
          puts messages.to_s
          next
        end
      end
    end

    unless local_error
      # If we made it this far, then we have a new set of POIs and we can delete the old ones.
      # Exclude any in use.
      # TODO: For OCC-957, this needs to be updated to match and update POIs in use using mobile API location id.
      landmark_set_landmark_ids = LandmarkSetLandmark.all.pluck(:landmark_id)
      Landmark.is_old.where.not(id: landmark_set_landmark_ids).destroy_all
      Landmark.is_old.where(id: landmark_set_landmark_ids).update_all(old: false)
      new_poi_count = Landmark.count
      messages << "Successfully loaded #{new_poi_count} POIs"
      messages << "count of pois with duplicate names: #{poi_total_duplicate_count}"
      messages << "count of pois with no city: #{poi_with_no_city}"
      messages << "count of pois with initial blank name: #{poi_blank_name_count}"
      puts messages.to_s
    end

  ensure
    task_run_state.update(value: false) unless is_already_running

    if local_error
      # If anything went wrong, delete the new POIs and reinstate the old POIs
      Landmark.where(old: false).delete_all
      Landmark.where(old: true).update_all(old: false)
    end
  end

  desc "Update Waypoints with an incorrect township as the city to the correct city"
  task fix_townships_city: :environment do
    messages = []
    Trip::CORRECTED_CITIES_HASHES.each do |tp|
      puts "Updating waypoints for #{tp[:incorrect]}"
      wps = Waypoint.where(city: tp[:incorrect])
      incorrect_waypoints_length = wps.length
      wps.update_all(city: tp[:correct])
      messages << "Updated #{incorrect_waypoints_length} waypoints with city name of #{tp[:incorrect]} to new city name of #{tp[:correct]}"

      # Correct the Waypoint name if it includes the incorrect township.
      Waypoint.where("name like ?", "%#{tp[:incorrect]}%").map do |wp|
        puts "Updating waypoint name #{wp.name}"
        wp.name.gsub!(tp[:incorrect], tp[:correct])
        wp.save!
      end
    end
    puts messages.to_s
  end
end # ecolane
