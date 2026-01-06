SimpleTranslationEngine.configure do |config|
  
  # # Only show Translation Keys namespaced under "global" or "pages"
  # config.visible_key_scope = lambda {
  #   where("name LIKE ? OR name LIKE ?", "global.%", "pages.%")
  # }
  
  # Hide any translation keys with "REFERNET" in the name
  config.hidden_key_scope = lambda {
    where("name LIKE ?", "%REFERNET%")
  }
  
end

# Extend Translation Engine classes with additional functionality
Rails.configuration.to_prepare do

  # Inject auth functionality into TranslationsController
  TranslationsController.class_eval do
    include TranslationsControllerExtensions
    authorize_resource
  end

  TranslationKeysController.class_eval do
    include TranslationsControllerExtensions
    authorize_resource

    def edit(id, return_path = simple_translation_engine.translations_path)

      google_api_key = ENV['GOOGLE_API_KEY']

      translator = (google_api_key ? GoogleTranslator.new(google_api_key) : DummyTranslator.new).from(I18n.default_locale)
      source_locale = Locale.of(I18n.default_locale)

      @google_translations = {}
      @return_path = return_path

      Locale.where(name: I18n.available_locales.sort).where.not(name: I18n.default_locale).each do |locale|
        unless @translation_key.translation(locale)
          @translation_key.translations.build(locale: locale)
        end

        unless @translation_key.name.blank?
          translator = translator.to(locale.name)
          source_translation = SimpleTranslationEngine.translate(source_locale, @translation_key.name).to_s
          target_translation = translator.translate(source_translation)
          @google_translations[locale.id] = target_translation
        end
      end
    end

    def update(id, return_path = simple_translation_engine.translations_path)

      Rails.logger.info "Saving translation.  Params = "
      Rails.logger.info params

      if @translation_key.update(translation_key_params)
        flash[:success] = "Translation Successfully Updated"
        redirect_to return_path
      else
        begin
          @translation_key.update!(translation_key_params)
        rescue Exception => e
          Rails.logger.info "Exception saving translation"
          Rails.logger.info e
        end
        render 'edit'
      end
    end
  end



  # If AWS_LOCALE_STORAGE is set, trigger upload of locale to AWS every time a record is updated
  if ENV['AWS_LOCALE_STORAGE'] == "true" && 
     ENV["RAILS_ENV"] == "production" # Only upload locales in production environment
    Translation.class_eval do
      include AwsLocaleUploadable
    end  
    TranslationKey.class_eval do
      include AwsLocaleUploadable
    end
  end

end
