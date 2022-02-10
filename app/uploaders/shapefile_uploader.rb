
# Helper class for uploading a zipped shapefile and reading it.
class ShapefileUploader
  require 'zip'

  attr_reader :errors, :custom_geo

  # Initialize with a path to a zipfile containing shapefiles
  def initialize(file, opts={})
    @file = file
    @path = opts[:path] || @file.tempfile.path
    # NOTE: the name field is specific to Travel Patterns
    @name = opts[:name]
    @agency = opts[:agency].present? ? Agency.find(opts[:agency]) : nil
    @filetype = opts[:content_type] || @file.content_type
    @model = opts[:geo_type].to_s.classify.constantize
    @column_mappings = opts[:column_mappings] || {name: 'NAME', state: 'STATEFP'}
    @errors = []
    @custom_geo = nil
  end

  # Call load to process the uploaded filepath into geometric database records
  def load
    @errors.clear
    Rails.logger.info "Unzipping file..."
    if @filetype == "application/zip"
      Zip::File.open(@path) do |zip_file|
        extract_shapefiles(zip_file) {|file| load_shapefile(file)}
      end
    else
      @errors << "Please upload a .zip file."
    end
    return self
  end

  def successful?
    @errors.empty?
  end

  private

  def extract_shapefiles(zip_file, &block)
    Rails.logger.info "Unpacking shapefiles..."
    zip_shp = zip_file.glob('**/*.shp').first
    if zip_shp
      zip_shp_paths = zip_shp.name.split('/')
      file_name = zip_shp_paths[zip_shp_paths.length - 1].sub '.shp', ''
      shp_name = nil
      Dir.mktmpdir do |dir|
        shp_name = "#{dir}/" + file_name + '.shp'
        zip_file.each do |entry|
          entry_names = entry.name.split('/')
          entry_name = entry_names[entry_names.length - 1]
          if entry_name.include?(file_name)
            entry.extract("#{dir}/" + entry_name)
          end
        end
        yield(shp_name)
      end
    else
      @errors << "Could not find .shp file in zipfile."
    end
  end

  def load_shapefile(shp_name)
    Rails.logger.info "Reading Shapes into #{@model.to_s} Table..."
    RGeo::Shapefile::Reader.open(shp_name, 
        assume_inner_follows_outer: true, 
        factory: RGeo::ActiveRecord::SpatialFactoryStore.instance.default) do |shapefile|
      fail_count = 0
      shapefile.each do |shape|
        attrs = {}
        attrs[:name] = shape.attributes[@column_mappings[:name]] if @column_mappings[:name]
        attrs[:state] = StateCodeDictionary.code(shape.attributes[@column_mappings[:state]]) if @column_mappings[:state]
        geom = shape.geometry
        Rails.logger.info "Loading #{attrs.values.join(",")}..."

        # NOTE: the below probably needs an update since it's pretty old
        # if the record fails to create, then we can just check for record errors and push those in
        # instead of doing a weird thing with active record logger
        record = ActiveRecord::Base.logger.silence do
          if @model.name == CustomGeography.name && Config.dashboard_mode == 'travel_patterns'
            @custom_geo = @model.create({ name: @name, agency: @agency })
            @custom_geo.update_attributes(geom:geom)
            # generally, the only error we're going to get are either the shapefile is invalid
            # or the name was taken already
            if @custom_geo.errors.present?
              @errors << "#{@custom_geo.errors.full_messages.to_sentence} for #{@custom_geo.name}."
            else
              @custom_geo
            end
          else
            @model.find_or_create_by(attrs).update_attributes(geom:geom)
          end
        end
        if record
          Rails.logger.info " SUCCESS!"
        else
          Rails.logger.info " FAILED."
          fail_count += 1
        end
      end
      @errors << "#{fail_count} records failed to load." if fail_count > 0
    end
  end

end
