module Waph
  class Installer
    def self.extend_options_parser(opts, options)
      nl = "\n" + ' ' * 37
      opts.on("-a", "--auto", "Run installer non-interactively.") do
        options[:auto] = true
      end
      opts.on("-u", "--username NAME", String,
              "Install this web application as the given#{nl}" <<
              "user instead of prompting for a username.") do |value|
        options[:desired_username] = value
      end
      opts.on("--dev",
              "Set to development mode. (Users, don't#{nl}" <<
              "use; for developers of this app only.)") do
        options[:rack_env] = "development"
      end
    end
    
    def initialize(options = {})
      @core = Waph::INSTANCE.dup
      @stdout = STDOUT
      options.each_pair do |key, value|
        instance_variable_set(:"@#{key}", value)
      end
    end
    
    def run
      raise "You must first call Waph.setup!" if !@core.set_up?
      before_install
      show_welcome_message
      run_steps
      show_completion_message
      true
    rescue Abort
      false
    rescue Interrupt
      puts
      false
    ensure
      after_install
    end
    
  protected
    class Abort < StandardError
    end
    
    class CommandError < Abort
    end
    
    def app_name
      @core.app_name
    end
    
    def source_root
      @core.source_root
    end
    
    def desired_username
      @desired_username
    end
    
    def restart_dir
      @core.restart_dir
    end
    
    def interactive?
      !@auto
    end
    
    def non_interactive?
      !interactive?
    end
    
    
    def dependencies
      if File.exist?("#{@core.source_root}/Gemfile")
        require 'platform_info/depcheck/bundler'
        ['bundler >= 1.0.10']
      else
        []
      end
    end
    
    def created_default_config_file(identifier, filename)
      # Hook for subclasses.
    end
    
    
    def before_install
      env = @rack_env || ENV['RACK_ENV'] || ENV['RAILS_ENV'] || 'production'
      ENV['RAILS_ENV'] = ENV['RACK_ENV'] = env
    end
    
    def show_welcome_message
    end
    
    def run_steps
      check_dependencies
      prompt_for_desired_username
      create_default_config_files
      install_gems
      migrate_database
      restart_web_app
    end
    
    def check_dependencies
      dependencies = self.dependencies.uniq
      if !dependencies.empty?
        new_screen
        puts "<banner>Checking for required software...</banner>"
        puts
        
        require 'platform_info/depcheck'
        missing_dependencies = []
        
        dependencies.each do |name|
          dep = PlatformInfo::Depcheck.find(name)
          raise "Installer bug: dependency '#{name}' not found. Please " +
            "ensure that the corresponding platform_info/depcheck file " +
            "is loaded." if !dep
          
          print " * #{dep.name}... "
          result = dep.check
          if result[0]
            if result[1]
              puts "<green>found at #{result[1]}</green>"
            else
              puts "<green>found</green>"
            end
          else
            if result[1]
              puts "<red>#{result[1]}</red>"
            else
              puts "<red>not found</red>"
            end
            missing_dependencies << dep
          end
        end
        
        if !missing_dependencies.empty?
          use_stderr do
            puts
            puts "<red>Some required software is not installed.</red>"
            puts "But don't worry, this installer will tell you how to install them."
            if interactive?
              puts
              puts "<b>Press Enter to continue, or Ctrl-C to abort.</b>"
              wait
            end
            
            new_screen
            puts "<banner>Installation instructions for required software</banner>"
            puts
            missing_dependencies.each do |dep|
              puts " * To install <yellow>#{dep.name}</yellow>:"
              dep.install_instructions.split("\n").each do |line|
                puts "   #{line}"
              end
              puts
            end
            raise Abort
          end
        end
      end
    end
    
    def prompt_for_desired_username(root_allowed = false)
      new_screen
      puts "<banner>Which user do you want #{app_name} to run as?</banner>"
      puts
      
      if @desired_username
        puts "<b>'#{@desired_username}' specified via command line option.</b>"
        if !user_exists?(@desired_username)
          puts "<red>This user does not exist.</red>"
          raise Abort
        elsif !root_allowed && @desired_username == "root"
          puts "<red>However, installing as root is not allowed for security reasons. " +
            "Please specify a different username instead.</red>"
          raise Abort
        end
        username = @desired_username
      elsif non_interactive?
        puts_error 'Please specify a username with --username.'
        raise Abort
      else
        if root_allowed || current_username != "root"
          message = "Please enter the desired username [#{current_username}]"
          default_value = current_username
        else
          message = "Please enter the desired username"
          default_value = nil
        end
        
        username = prompt(message, default_value) do |value|
          if user_exists?(value)
            if root_allowed || value != "root"
              true
            else
              puts_error "Installing as root is not allowed for security reasons."
              false
            end
          else
            puts_error "This user does not exist."
            false
          end
        end
      end
      
      if current_username != "root" && current_username != username
        puts
        if username == "root"
          puts "<yellow>In order to install #{app_name} as '#{username}', " +
            "please re-run this program as root.</yellow>"
        else
          puts "<yellow>In order to install #{app_name} as '#{username}', " +
            "please re-run this\n" +
            "installer as either '#{username}' or as 'root'.</yellow>"
        end
        raise Abort
      else
        @desired_username = username
      end
      @core.username = @desired_username
    end
    
    def create_default_config_files
      new_screen
      puts "<banner>Checking whether config files are available...</banner>"
      puts
      
      nonexistent_files = []
      created_files = []
      
      @core.config_files.each_pair do |identifier, basename|
        print " <b>* #{basename}...</b>"
        filename = @core.config_filename(identifier, false)
        if filename
          puts " <green>#{filename}</green>"
        else
          puts " <red>not found</red>"
          nonexistent_files << identifier
        end
      end
      
      if non_interactive?
        if !nonexistent_files.empty?
          use_stderr do
            puts
            if nonexistent_files.size > 1
              puts "<red>Please create the following config files first:</red>"
            else
              puts "<red>Please create the following config file first:</red>"
            end
            puts
            nonexistent_files.each do |identifier|
              filename = @core.preferred_config_filename(identifier)
              puts " <red>* #{filename}</red>"
            end
            raise Abort
          end
        end
      else
        begin
          if !nonexistent_files.empty?
            puts
            puts "Some config files do not exist. Creating example files..."
            puts
            sh! "mkdir -p #{@core.preferred_config_dir}"
            sh! "chown #{@desired_username} #{@core.preferred_config_dir}"
            sh! "chgrp #{group_for(@desired_username)} #{@core.preferred_config_dir}"
          end
        
          nonexistent_files.each do |identifier|
            basename = @core.config_files[identifier]
            filename = @core.preferred_config_filename(identifier)
            created_files << identifier
            sh! "cp #{@core.source_root}/config/#{basename}.example #{filename}"
            sh! "chown #{@desired_username} #{filename}"
            sh! "chgrp #{group_for(@desired_username)} #{filename}"
            created_default_config_file(identifier, filename)
          end
        rescue CommandError
          use_stderr do
            new_screen
            puts '<red>Some example configuration files cannot be created.</red>'
            puts
            if current_username == "root"
              puts "You need to create the following configuration files:"
              puts
              @core.config_files.each_key do |identifier|
                puts " * #{@core.preferred_config_filename(identifier)}"
              end
              puts
              puts "Please use these files as examples:"
              puts
              @core.config_files.each_pair do |identifier, basename|
                puts " * #{@core.source_root}/config/#{basename}.example"
                puts " * #{@core.source_root}/config/#{basename}.example"
              end
              puts
              puts "<yellow>Once you've created the aforementioned configuration files, please re-run this"
              puts "program.</yellow>"
            else
              puts "This is probably because you're not running this program as <b>root</b>."
              puts "Please re-run this program as root, e.g. with <b>sudo</b>."
            end
            raise Abort
          end
        end
      
        if created_files.size > 0
          new_screen
          puts "<banner>You need to edit some Union Station configuration files</banner>"
          puts
          if created_files.size > 1
            puts "The following example configuration files have been created."
          else
            puts "The following example configuration file has been created."
          end
          puts
          created_files.each do |identifier|
            filename = @core.preferred_config_filename(identifier)
            puts " * <b>#{filename}</b>"
          end
          puts
          if created_files.size > 1
            puts "Please edit the aforementioned configuration files."
          else
            puts "Please edit this configuration file."
          end
          if interactive?
            puts "Once you're done press Enter to continue, or press Ctrl-C to cancel."
          end
          wait
        
          created_files.each do |identifier|
            basename = @core.config_files[identifier]
            line
            puts
            while !prompt_confirmation("Are you done editing #{basename}?")
              filename = @core.preferred_config_filename(identifier)
              puts "Please edit <b>#{filename}</b> and press Enter when you're done."
              wait
            end
            puts
          end
        end
      end
    end
    
    def install_gems
      if File.exist?("#{@core.source_root}/Gemfile")
        new_screen
        puts "<banner>Installing #{app_name} dependency gems...</banner>"
        puts
        
        bundle = locate_ruby_command('bundle')
        if !bundle
          puts_error 'Cannot find Bundler.'
          raise Abort
        end
        
        if @core.rack_env == 'development'
          install_gems_into_app_dir(bundle)
        else
          install_gems_into_home(bundle)
        end
      end
    end
    
    def migrate_database
      if is_rails_app?
        new_screen
        puts "<banner>Creating or migrating database schema...</banner>"
        puts
        
        rake!('db:migrate SCHEMA=/dev/null --trace')
      end
    end
    
    def restart_web_app
      new_screen
      puts "<banner>Restarting #{app_name}...</banner>"
      puts
      sh "mkdir -p #{@core.restart_dir}"
      sh "touch #{@core.restart_dir}/restart.txt"
      sh "chown #{@desired_username} #{@core.restart_dir}"
      sh "chown #{@desired_username} #{@core.restart_dir}/restart.txt"
      sh "chgrp #{group_for(@desired_username)} #{@core.restart_dir}"
      sh "chgrp #{group_for(@desired_username)} #{@core.restart_dir}/restart.txt"
    end
    
    def show_completion_message
      new_screen
      text = <<-EOF
        <green>#{app_name} has been installed or upgraded!</green>

        To (re-)deploy on Phusion Passenger, use one of the following configuration
        snippets. Be sure to remove any old configuration snippets for
        #{app_name} that you already had.

        <yellow>Phusion Passenger for Apache</yellow>
        <b>
           <VirtualHost *:80>
               ServerName www.example.com
               DocumentRoot #{source_root}/public
               PassengerUser #{desired_username}
               PassengerRestartDir #{restart_dir}
               RailsEnv production
           </VirtualHost>
        </b>
        <yellow>Phusion Passenger for Nginx</yellow>
        <b>
           server {
               listen 80;
               server_name www.example.com;
               root #{source_root}/public;
               passenger_enabled on;
               passenger_user #{desired_username};
               rails_env production;
           }
        </b>
        Enjoy! :-)
      EOF
      text.gsub!(/^        /, '')
      text.strip!
      puts text
    end
    
    def after_install
      # Reset terminal colors.
      STDOUT.write("\e[0m")
      STDOUT.flush
    end
    
    
    def install_gems_into_app_dir(bundle)
      sh! "#{bundle} update"
    end
    
    def install_gems_into_home(bundle)
      source_root        = @core.source_root
      bundle_path        = @core.preferred_gem_bundle_path
      bundle_path_root   = @core.preferred_gem_bundle_path_root
      bundle_config_path = @core.preferred_gem_bundle_config_path
      
      begin
        # We create the following directory structure:
        #
        # ~/.app                                             <-- preferred_gem_bundle_path_root
        # ~/.app/bundle/ruby-1.8                             <-- preferred_gem_bundle_path
        # ~/.app/bundle/ruby-1.8/config-1.0.0                <-- preferred_gem_bundle_config_path
        # ~/.app/bundle/ruby-1.8/config-1.0.0/Gemfile
        # ~/.app/bundle/ruby-1.8/config-1.0.0/Gemfile.lock
        # ~/.app/bundle/ruby-1.8/config-1.0.0/.bundle
        
        sh! "mkdir -p #{bundle_config_path}"
        
        # The following is a hack to force Bundler to only write to
        # bundle_config_path, not to the directory containing the
        # real Gemfile.
        puts "# Creating proxy Gemfile: #{bundle_config_path}/Gemfile"
        File.open("#{bundle_config_path}/Gemfile", "w") do |f|
          f.write(%Q{
            gemfile = ENV['SOURCE_ROOT'] + '/Gemfile'
            eval(File.read(gemfile), binding, gemfile)
          })
        end

        # Note that we don't lock the bundle. Otherwise the user has to rerun
        # the installer whenever it changes the database adapter in database.yml.
        File.unlink("#{bundle_config_path}/Gemfile.lock") rescue nil
        sh! "env SOURCE_ROOT=#{source_root} #{bundle} install --path #{bundle_path} " +
          "--gemfile=#{bundle_config_path}/Gemfile"
        File.unlink("#{bundle_config_path}/Gemfile.lock") rescue nil
        
        # Since Bundler might be run as root but instructed to install to a
        # user's home dir, we might need to fix permissions.
        sh! "chown -R #{@desired_username} #{bundle_path_root}"
        sh! "chgrp -R #{group_for(@desired_username)} #{bundle_path_root}"
      rescue CommandError
        use_stderr do
          new_screen
          puts "<red>Cannot install #{app_name} dependency gems.</red>"
          puts
          puts "Possible causes are:"
          puts
          puts " * Your Internet connection is down. Please try again after your Internet"
          puts "   connection has been restored."
          puts " * Permission problems. Please ensure that the <b>#{current_username}</b> user can write to"
          puts "   the directory <b>#{bundle_path}</b>."
          puts
          puts "Please check the error messages in the backlog for details."
          raise Abort
        end
      end
    end
    
    
    def use_stderr
      old_stdout = @stdout
      begin
        @stdout = STDERR
        yield
      ensure
        @stdout = old_stdout
      end
    end
    
    def print(text)
      @stdout.write(substitute_color_tags(text))
      @stdout.flush
    end
    
    def puts(text = nil)
      if text
        @stdout.puts(substitute_color_tags(text))
      else
        @stdout.puts
      end
      @stdout.flush
    end
    
    def puts_error(text)
      STDERR.puts(substitute_color_tags("<red>#{text}</red>"))
      STDERR.flush
    end
    
    def render_template(name, options = {})
      puts ConsoleTextTemplate.new({ :file => name }, options).result
    end
    
    def new_screen
      puts
      line
      puts
    end
    
    def line
      puts "--------------------------------------------"
    end
    
    def prompt(message, default_value = nil)
      done = false
      while !done
        print "#{message}: "
        
        if non_interactive? && default_value
          puts default_value
          return default_value
        end
        
        begin
          result = STDIN.readline
        rescue EOFError
          exit 2
        end
        result.strip!
        if result.empty?
          if default_value
            result = default_value
            done = true
          else
            done = false
          end
        else
          done = !block_given? || yield(result)
        end
      end
      result
    end
    
    def prompt_confirmation(message)
      result = prompt("#{message} [y/n]") do |value|
        if value.downcase == 'y' || value.downcase == 'n'
          true
        else
          puts_error "Invalid input '#{value}'; please enter either 'y' or 'n'."
          false
        end
      end
      return result.downcase == 'y'
    end
    
    def wait(timeout = nil)
      if interactive?
        if timeout
          require 'timeout' unless defined?(Timeout)
          begin
            Timeout.timeout(timeout) do
              STDIN.readline
            end
          rescue Timeout::Error
            # Do nothing.
          end
        else
          STDIN.readline
        end
      end
    rescue Interrupt
      raise Abort
    end
    
    
    def sh(*args)
      puts "# #{args.join(' ')}"
      result = system(*args)
      if result
        true
      elsif $?.signaled? && $?.termsig == Signal.list["INT"]
        raise Interrupt
      else
        false
      end
    end
    
    def sh!(*args)
      if !sh(*args)
        puts_error "*** Command failed: #{args.join(' ')}"
        raise CommandError
      end
    end
    
    def rake(*args)
      sh("#{rake_command} #{args.join(' ')}")
    end
    
    def rake!(*args)
      sh!("#{rake_command} #{args.join(' ')}")
    end
    
    
    def current_username
      @current_username ||= `whoami`.strip
    end
    
    def user_exists?(username)
      require 'etc' if !defined?(Etc)
      begin
        Etc.getpwnam(username)
        true
      rescue ArgumentError
        false
      end
    end
    
    def group_for(username)
      Etc.getgrgid(Etc.getpwnam(username).gid).name
    end
    
  private
    DEFAULT_TERMINAL_COLORS = "\e[0m\e[37m\e[40m"
    
    class ConsoleTextTemplate
      def initialize(input, options = {})
        @buffer = ''
        if input[:file]
          data = File.read(input[:file])
        else
          data = input[:text]
        end
        @template = ERB.new(substitute_color_tags(data),
          nil, nil, '@buffer')
        options.each_pair do |name, value|
          instance_variable_set(:"@#{name}", value)
        end
      end
      
      def result
        @template.result(binding)
      end
    end
    
    def substitute_color_tags(data)
      data = data.gsub(%r{<b>(.*?)</b>}m, "\e[1m\\1#{DEFAULT_TERMINAL_COLORS}")
      data.gsub!(%r{<red>(.*?)</red>}m, "\e[1m\e[31m\\1#{DEFAULT_TERMINAL_COLORS}")
      data.gsub!(%r{<green>(.*?)</green>}m, "\e[1m\e[32m\\1#{DEFAULT_TERMINAL_COLORS}")
      data.gsub!(%r{<yellow>(.*?)</yellow>}m, "\e[1m\e[33m\\1#{DEFAULT_TERMINAL_COLORS}")
      data.gsub!(%r{<banner>(.*?)</banner>}m, "\e[33m\e[44m\e[1m\\1#{DEFAULT_TERMINAL_COLORS}")
      data
    end
    
    def is_rails_app?
      File.exist?("#{@core.source_root}/config/environment.rb") &&
        File.read("#{@core.source_root}/config/environment.rb") =~ /rails/i
    end
    
    def ruby
      @ruby ||= begin
        require 'rbconfig' if !defined?(Config)
        Config::CONFIG['bindir'] + '/' + Config::CONFIG['RUBY_INSTALL_NAME'] + Config::CONFIG['EXEEXT']
      end
    end
    
    def ruby_engine
      @core.ruby_engine
    end
    
    def ruby_major_minor_version
      @core.ruby_major_minor_version
    end
    
    # Locate a Ruby command, e.g. 'gem', 'rake', 'bundle', etc. Instead of naively
    # looking in $PATH, this function uses a variety of search heuristics to find
    # the command that's really associated with the current Ruby interpreter. It
    # should never locate a command that's actually associated with a different
    # Ruby interprete.
    def locate_ruby_command(name)
      if RUBY_PLATFORM =~ /darwin/ &&
         ruby =~ %r(\A/System/Library/Frameworks/Ruby.framework/Versions/.*?/usr/bin/ruby\Z)
        # On OS X we must look for Ruby binaries in /usr/bin.
        # RubyGems puts executables (e.g. 'rake') in there, not in
        # /System/Libraries/(...)/bin.
        filename = "/usr/bin/#{name}"
      else
        filename = File.dirname(ruby) + "/#{name}"
      end
      
      if !File.file?(filename) || !File.executable?(filename)
        # RubyGems might put binaries in a directory other
        # than Ruby's bindir. Debian packaged RubyGems and
        # DebGem packaged RubyGems are the prime examples.
        begin
          require 'rubygems' unless defined?(Gem)
          filename = Gem.bindir + "/#{name}"
        rescue LoadError
          filename = nil
        end
      end
      
      if !filename || !File.file?(filename) || !File.executable?(filename)
        # Looks like it's not in the RubyGems bindir. Search in $PATH, but
        # be very careful about this because whatever we find might belong
        # to a different Ruby interpreter than the current one.
        ENV['PATH'].split(':').each do |dir|
          filename = "#{dir}/#{name}"
          if File.file?(filename) && File.executable?(filename)
            shebang = File.open(filename, 'rb') do |f|
              f.readline.strip
            end
            if shebang == "#!#{ruby}"
              # Looks good.
              break
            end
          end
          
          # Not found. Try next path.
          filename = nil
        end
      end
      
      filename
    end
    
    def rake_command
      require 'platform_info/ruby' unless defined?(PlatformInfo) && PlatformInfo.respond_to?(:rake_command)
      rake = PlatformInfo.rake_command
      if !rake
        puts_error 'Cannot find Rake.'
        raise Abort
      end
      "#{rake} WAPH_USER=#{@desired_username} #{@core.env_var_name_for_identifier(:log_file)}=/dev/null"
    end
  end
end