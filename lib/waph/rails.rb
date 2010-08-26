module Waph
  module Rails
    def self.setup(rails_config, core = Waph::INSTANCE)
      rails_config.database_configuration_file = core.config_filename(:database)
      rails_config.log_path = core.log_filename
    end
  end
end