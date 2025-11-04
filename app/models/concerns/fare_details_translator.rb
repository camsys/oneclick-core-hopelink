# Sets up translations for fare details on a service (modeled after Describable)
module FareDetailsTranslator
  
  def self.included(base)
    # This block of code creates localized description setters and getters
    I18n.available_locales.each do |locale|

      # Create localized getters
      define_method("#{locale}_fare_text") do
        self.send(:fare_text, locale)
      end

      define_method("#{locale}_url_partner_text") do
        self.send(:url_partner_text, locale)
      end
      
      # Create localized setters
      define_method("#{locale}_fare_text=") do |value|
        self.send(:set_fare_text_translation, locale, value)
      end

      define_method("#{locale}_url_partner_text=") do |value|
        self.send(:set_url_partner_text_translation, locale, value)
      end
    end
    
    # Destroy any description translations along with the including model
    base.before_destroy :delete_translations
  
  end
  
  # Gets the fare text, translated into the passed locale
  def fare_text(locale=I18n.default_locale)
    SimpleTranslationEngine.translate(locale, fare_text_translation_key)
  end
  
  # Sets the fare text for the given locale
  def set_fare_text_translation(locale, value)
    SimpleTranslationEngine.set_translation(locale, fare_text_translation_key, value)
  end

  # Gets the url partner text, translated into the passed locale
  def url_partner_text(locale=I18n.default_locale)
    SimpleTranslationEngine.translate(locale, url_partner_text_translation_key)
  end

  # Sets the url partner text for the given locale
  def set_url_partner_text_translation(locale, value)
    SimpleTranslationEngine.set_translation(locale, url_partner_text_translation_key, value)
  end
  
  # Deletes the translations associated with this model
  def delete_translations
    TranslationKey.find_by(name: fare_text_translation_key).try(:destroy)
    TranslationKey.find_by(name: url_partner_text_translation_key).try(:destroy)
  end
  
  # Builds a fare text translation key based on the class name and id of the including model
  def fare_text_translation_key
    "#{self.class.name.downcase}_#{self.id}_fare_text"
  end

  # Builds a url partner text translation key based on the class name and id of the including model
  def url_partner_text_translation_key
    "#{self.class.name.downcase}_#{self.id}_url_partner_text"
  end
  
  # Returns a hash of all fare text translations, keyed by locale
  def fare_texts
    I18n.available_locales.map {|l| [l, fare_text(l)] }.to_h
  end

  # Returns a hash of all fare text translations, keyed by locale
  def url_partner_texts
    I18n.available_locales.map {|l| [l, url_partner_text(l)] }.to_h
  end
  
  # Sets the fare texts from a hash of locale:value pairs
  def set_fare_texts_from_hash(fare_texts_hash={})
    fare_texts_hash.each do |loc, ft|
      set_fare_text_translation(loc, ft)
    end
  end

  # Sets the url_partner texts from a hash of locale:value pairs
  def set_url_partner_texts_from_hash(partner_texts_hash={})
    partner_texts_hash.each do |loc, upt|
      set_url_partner_text_translation(loc, upt)
    end
  end
  
end
