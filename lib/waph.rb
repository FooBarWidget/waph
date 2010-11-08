# Web Application Packaging Helper
require 'etc'

module Waph
  class Core
    attr_reader :app_id, :app_name, :app_version, :source_root, :config_files, :username
    
    def setup(options = {})
      @app_id       = options[:app_id]
      @app_name     = options[:app_name]
      @app_version  = options[:app_version]
      @source_root  = options[:source_root]
      raise "The :app_id option is required" if !@app_id
      raise "The :app_name option is required" if !@app_name
      raise "The :app_version option is required" if !@app_version
      raise "The :source_root option is required" if !@source_root
      
      @installer    = options[:installer] || {}
      @config_files = options[:config_files] || {}
      
      # Pretend like we're running as this user. Used for various filename lookups.
      @username = options[:username] || ENV['WAPH_USER'] || `whoami`.strip
    end
    
    def set_up?
      !!@app_id
    end
    
    def username=(value)
      @username = value
      @uid = nil
      @gid = nil
      @home_dir = nil
    end
    
    def uid
      @uid ||= begin
        require 'etc' if !defined?(Etc)
        Etc.getpwnam(@username).uid
      end
    end
    
    def gid
      @gid ||= begin
        require 'etc' if !defined?(Etc)
        Etc.getpwnam(@username).gid
      end
    end
    
    def env_var_name_for_identifier(identifier)
      result = "#{@app_id}_#{identifier}"
      result.upcase!
      result.gsub!(/[ \-\.]+/, '_')
      result.gsub!(/__+/, '_')
      result
    end
    
    
    ##### Configuration file management #####
    
    def config_filename(identifier, required = true)
      basename = @config_files[identifier]
      raise "Unknown configuration file identifier" if !basename
      filename =
        check_file_existance(ENV[env_var_name_for_identifier(identifier)]) ||
        check_file_existance("#{@source_root}/config/#{basename}") ||
        check_file_existance("#{home_dir}/.#{@app_id}/#{basename}") ||
        check_file_existance(sysconfigdir("#{@app_id}/#{basename}"))
      if required && !filename
        message = "The configuration file '#{basename}' cannot be found. "
        if @installer
          message << "#{@app_name} is probably not installed properly. "
          if installer_command
            message << "Please (re)run the installer: #{installer_command}"
          else
            message << "Please (re)run the installer."
          end
        else
          message << "Please create it."
        end
        raise(message)
      else
        filename
      end
    end
    
    def load_yaml_config(identifier, required = true)
      require 'yaml' unless defined?(YAML)
      filename = config_filename(identifier, required)
      if filename
        YAML.load_file(filename)
      else
        nil
      end
    end
    
    def preferred_config_dir
      if username == "root"
        sysconfigdir("#{@app_id}")
      else
        "#{home_dir}/.#{@app_id}"
      end
    end
    
    def preferred_config_filename(identifier)
      basename = @config_files[identifier]
      raise "Unknown configuration file identifier" if !basename
      "#{preferred_config_dir}/#{basename}"
    end
    
    
    ##### Log file management #####
    
    def log_filename
      env_name = Waph.env_var_name_for_identifier(:log_file)
      if ENV[env_name]
        ENV[env_name]
      else
        env = ENV['RACK_ENV'] || ENV['RAILS_ENV'] || 'development'
        
        # When in development mode the developer probably wants the log
        # file to be in the source root's "log" directory, but end users
        # probably want it elsewhere. We check whether the user wants us
        # to write to @source_root/log or elsewhere by checking whether
        # @source_root/log/logfile is writable.
        #
        # But once the web app is deployed, there may or may not be a "log"
        # directory in the source root. In non-development mode we do not
        # create the log directory so that the writability check always
        # fails if the log directory doesn't exist; the user has to
        # explicitly create the log directory in the source root to signal
        # desire to use it. In development mode we attempt to create this
        # log directory first because we know the chance is high that the
        # developer wants to use this directory even if he didn't create
        # it yet.
        #
        # We explicitly don't use File.writable? here because that
        # doesn't work well with ACLs.
        filename = "#{@source_root}/log/#{env}.log"
        begin
          if env == "development" && !File.exist?("#{@source_root}/log")
            Dir.mkdir("#{@source_root}/log")
            File.chown(uid, gid, "#{@source_root}/log")
          end
          
          File.open(filename, "a").close
          writable = true
        rescue Errno::EACCES
          writable = false
        end
        
        if writable
          filename
        else
          if @username == "root"
            filename = systemlogdir("#{app_id}/#{env}.log")
          else
            filename = "#{home_dir}/.#{@app_id}/#{env}.log"
          end
          dir = File.dirname(filename)
          if !File.exist?(dir)
            require 'fileutils' if !defined?(FileUtils)
            FileUtils.mkdir_p(dir)
            File.chown(uid, gid, dir)
          end
          filename
        end
      end
    end
    
    
    ##### Bundler and Gemfile management #####
    
    def prepare_for_bundler!
      # Used by the proxy Gemfile.
      ENV['SOURCE_ROOT'] = @source_root
      
      path = gemfile_path
      if path
        ENV['BUNDLE_GEMFILE'] = path
      elsif @installer
        message = "Cannot find the #{@app_name} gem bundle directory. This " +
          "probably means #{@app_name} isn't properly installed yet, or " +
          "that its installation somehow become corrupted. "
        if installer_command
          message << "Please (re-)run the #{@app_name} installer: #{installer_command}"
        else
          message << "Please (re-)run the #{@app_name} installer."
        end
        raise message
      else
        raise "Not all #{@app_name} gem dependencies are installed. " +
          "Please run 'bundle install'."
      end
    end
    
    def gemfile_path
      if File.exist?("#{@source_root}/.bundle")
        "#{@source_root}/Gemfile"
      else
        path = "#{preferred_gem_bundle_config_path}/Gemfile"
        if File.exist?(path)
          path
        elsif File.exist?("#{@source_root}/Gemfile")
          "#{@source_root}/Gemfile"
        else
          nil
        end
      end
    end
    
    def preferred_gem_bundle_path
      if @username == "root"
        libdir("#{@app_id}/bundle/#{ruby_engine}-#{ruby_major_minor_version}")
      else
        "#{home_dir}/.#{@app_id}/bundle/#{ruby_engine}-#{ruby_major_minor_version}"
      end
    end
    
    def preferred_gem_bundle_path_root
      if @username == "root"
        libdir(@app_id)
      else
        "#{home_dir}/.#{@app_id}"
      end
    end
    
    def preferred_gem_bundle_config_path
      if @username == "root"
        libdir("#{@app_id}/bundle/#{ruby_engine}-#{ruby_major_minor_version}/config-#{@app_version}")
      else
        "#{home_dir}/.#{@app_id}/bundle/#{ruby_engine}-#{ruby_major_minor_version}/config-#{@app_version}"
      end
    end
    
    
    ##### Misc #####
    
    def installer_command
      if @installer.is_a?(String)
        if @installer.include?("/")
          result = @installer.dup
        else
          result = "#{@source_root}/bin/#{@installer}"
        end
        result << " -u #{@username}"
        result
      else
        nil
      end
    end
    
    def restart_dir
      if @username == "root"
        "/tmp/#{@app_id}"
      else
        "#{home_dir}/.#{@app_id}/tmp"
      end
    end
    
  private
    def check_file_existance(filename)
      if filename && File.exist?(filename)
        filename
      else
        nil
      end
    end
    
    # read-only single-machine data
    def sysconfigdir(filename)
      "/etc/#{filename}"
    end
    
    # object code libraries
    def libdir(filename)
      "/usr/lib/#{filename}"
    end
    
    def systemlogdir(filename)
      "/var/log/#{filename}"
    end
    
    def home_dir
      @home_dir ||= Etc.getpwnam(@username).dir
    end
    
    def ruby_engine
      @ruby_engine ||=
        if defined?(RUBY_ENGINE)
          RUBY_ENGINE
        else
          "ruby"
        end
    end
    
    def ruby_major_minor_version
      @ruby_major_minor_version ||= begin
        require 'rbconfig' if !defined?(Config)
        Config::CONFIG['MAJOR'] + '.' + Config::CONFIG['MINOR']
      end
    end
  end
  
  
  ##### End of Waph::Core #####
  
  
  INSTANCE = Core.new
  
  # Create convenience methods on Waph for calling methods on
  # the default singleton Waph::Core instance object. For example:
  #
  #   Waph.config_filename(:settings)
  #
  # is the same as calling
  #
  #   Waph::INSTANCE.config_filename(:settings)
  Core.public_instance_methods(false).each do |method_name|
    if method_name.to_s.include?("=")
      class_eval("def self.#{method_name}(value); INSTANCE.#{method_name} value; end",
        __FILE__, __LINE__)
    else
      class_eval("def self.#{method_name}(*args); INSTANCE.#{method_name}(*args); end",
        __FILE__, __LINE__)
    end
  end
end