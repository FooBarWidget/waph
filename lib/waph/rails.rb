module Waph
  module Rails
    def self.setup(rails_config, core = Waph::INSTANCE)
      if rails_config.respond_to?(:paths)
        rails_config.paths.database = core.config_filename(:database)
        rails_config.paths.log = core.log_filename
      else
        rails_config.database_configuration_file = core.config_filename(:database)
        rails_config.log_path = core.log_filename
      end
    end
  end
end