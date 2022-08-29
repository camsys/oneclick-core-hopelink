class Landmark < Place
  include GeoKitchen
  include LeafletAmbassador

  attr_reader :geom_buffer
  make_attribute_mappable :geom
  make_attribute_mappable :geom_buffer
  acts_as_geo_ingredient attributes: [:name, :buffer]

  ### Associations ###
  belongs_to :agency
  has_many :landmark_set_landmarks, inverse_of: :landmark
  has_many :landmark_sets, through: :landmark_set_landmarks

  ### Validations ####
  validates :name, uniqueness: true
  validates :name, presence: true
  validates :lat , numericality: { greater_than_or_equal_to:  -90, less_than_or_equal_to:  90 }
  validates :lng, numericality: { greater_than_or_equal_to: -180, less_than_or_equal_to: 180 }

  #### Scopes ####
  scope :is_old, -> { where(:old => true) }
  scope :is_new, -> { where(:old => false) }

  #### METHODS ####
  # Load new landmarks from CSV
  # CSV must have the following columns: Name, Street Number, Route, Address, City, State, Zip, Lat, Lng, Types
  def self.update file
    #require 'open-uri'
    require 'csv'
    landmarks_file = open(file)

    # Iterate through CSV.
    failed = false
    message = ""
    Landmark.update_all(old: true)
    line = 2 #Line 1 is the header, start with line 2 in the count
    numberOfLines = 0 #Incremented once for every line in CSV
    begin
      CSV.foreach(landmarks_file, {:col_sep => ",", :headers => true}) do |row|
        numberOfLines += 1
        begin
          #If we have already created this Landmark, don't create it again.
          l = Landmark.create!({
        	  name: row[0],
        	  street_number: row[1],
        	  route: row[2],
        	  city: row[3],
        	  state: row[4],
        	  zip: row[5],
        	  lat: row[6],
        	  lng: row[7],
            old: false
          })
        rescue Exception => msg
          #Found an error, back out all changes and restore previous POIs
          message = 'Error on line ' + line.to_s + ' of .csv file - ' + msg.to_s
          Rails.logger.info message
          Rails.logger.info 'All changes have been rolled-back and previous Landmarks have been restored'
          Landmark.is_new.delete_all
          Landmark.is_old.update_all(old: false)
          failed = true
          break
        end
        line += 1
      end
    rescue
      failed = true
      message = 'Error Reading File'
      Rails.logger.info message
      Rails.logger.info 'All changes have been rolled-back and previous Landmarks have been restored'
      Landmark.is_new.delete_all
      Landmark.is_old.update_all(old: false)
      failed = true
    end

    if failed
      return false, message
    else
      return true, numberOfLines.to_s + " landmarks loaded"
    end

  end #Update

  def geom_buffer
    @factory = RGeo::ActiveRecord::SpatialFactoryStore.instance.default
    output_geom = []
    if self.geom
      if self.geom.is_a?(RGeo::Geos::CAPIPointImpl)
        # Convert point into polygon.
        geom = self.geom.buffer(0.001)
        output_geom = [ geom ]
      end
    else
      @errors << "#{this.to_s} could not be converted to a geometry."
    end
    output_geom = @factory.multi_polygon([]).union(geom)
    RGeo::Feature.cast(output_geom, RGeo::Feature::MultiPolygon)
  end

  def to_s
    "#{name}"
  end

  # Returns a GeoIngredient referring to this landmark
  def to_geo
    GeoIngredient.new('Landmark', name: name, buffer: 0)
  end

  def self.search(term)
    where('LOWER(name) LIKE :term', term: "%#{term.downcase}%")
  end

end #Landmark
