module Waph
  module GemfileHelper
    def self.install(dsl_object)
      dsl_object.extend(self)
    end
    
    def declare_database_gems
      return if !database_config
      database_config.each_key do |group_name|
        declare_database_gems_for_group(group_name)
      end
    end
    
    def declare_database_gems_for_group(group_name)
      return unless database_config
      config = database_config[group_name.to_s]
      return unless config
      
      group(group_name) do
        if config.has_key?("gem")
          # May be set to nil or false in order not to load a gem.
          gem_name = config["gem"]
        else
          adapter = config["adapter"]
          case adapter
          when "postgresql"
            gem_name = "pg"
          when "sqlite3"
            gem_name = "sqlite3-ruby"
          else
            gem_name = adapter
          end
        end
        
        gem(gem_name) if gem_name
      end
    end
    
  private
    def database_config
      @database_config ||= Waph.load_yaml_config(:database, false)
    end
  end
end