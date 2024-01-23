require "yaml"
require "erb"
require 'open-uri'
# require 'open-uri'
require 'railtie' if defined?(Rails)

# A simple settings solution using a YAML file. See README for more information.
class Configlogic < Hash
  class MissingSetting < StandardError; end
  class RedisNotPresent < StandardError; end

  class OperationNotAllowed < StandardError; end

  class DynamicCallbackHandler
    def self.add_after_commit_callback_for_column(current_klass, klass, column_name)
      if klass
        klass.after_commit :handle_config_change, if: -> { saved_change_to_attribute?(column_name) }
        # klass.after_commit :handle_config_change
    
        klass.define_method(:handle_config_change) do
          current_klass.burst_cache!
        end
      end
    end
  end
  
  class << self

    def name # :nodoc:
      self.superclass != Hash && instance.key?("name") ? instance.name : super
    end

    # Enables Settings.get('nested.key.name') for dynamic access
    def get_value(key)
      parts = key.split('.')
      curs = self
      while p = parts.shift
        curs = curs.send(p)
      end
      curs
    end

    def get(key)
      method = get_value(key)
      raise OperationNotAllowed.new unless method.is_a? Proc
  
      method.call
    end
  
    def burst_cache!
      if cache_values_to_redis
        keys = "config-#{redis_key.call}-*"
        p "bursting cache for keys: #{keys}"
        Rails.cache.delete_matched(keys)
      end
    end

    def source(value = nil)
      @source ||= value
      if self.config_class && !self.config_classconstantize.respond_to?(:handle_config_change)
        DynamicCallbackHandler.add_after_commit_callback_for_column(self, self.config_class.constantize, self.config_class_column)
      end
      @source
    end

    def redis_key(&value)
      @redis_key ||= value
    end

    def apartment_identifier_class(value = :Client)
      @apartment_identifier_class ||= value.to_s
    end

    def apartment_identifier_column(value = :tenant_id)
      @apartment_identifier_column ||= value.to_s
    end

    def config_class(value = nil)
      @config_class ||= value
    end

    def config_class_column(value = nil)
      @config_class_column ||= value
    end

    def cache_values_to_redis(value = false)
      @cache_values_to_redis ||= value
    end

    def get_value_from_db(value = false)
      @get_value_from_db ||= value
    end

    def namespace(value = nil)
      @namespace ||= value
    end
  
    def suppress_errors(value = nil)
      @suppress_errors ||= value
    end

    def [](key)
      instance.fetch(key.to_s, nil)
    end

    def []=(key, val)
      # Setting[:key][:key2] = 'value' for dynamic settings
      val = new(val, source) if val.is_a? Hash
      instance.store(key.to_s, val)
      instance.create_accessor_for(key, val)
    end

    def load!
      instance
      true
    end

    def reload!
      @instance = nil
      load!
    end

    private
      def instance
        return @instance if @instance
        @instance = new
        create_accessors!
        @instance
      end

      def method_missing(name, *args, &block)
        instance.send(name, *args, &block)
      end

      # It would be great to DRY this up somehow, someday, but it's difficult because
      # of the singleton pattern.  Basically this proxies Setting.foo to Setting.instance.foo
      def create_accessors!
        instance.each do |key,val|
          create_accessor_for(key)
        end
      end

      def create_accessor_for(key)
        return unless key.to_s =~ /^\w+$/  # could have "some-setting:" which blows up eval
        instance_eval "def #{key}; instance.send(:#{key}); end"
      end
  end

  # Initializes a new settings object. You can initialize an object in any of the following ways:
  #
  #   Settings.new(:application) # will look for config/application.yml
  #   Settings.new("application.yaml") # will look for application.yaml
  #   Settings.new("/var/configs/application.yml") # will look for /var/configs/application.yml
  #   Settings.new(:config1 => 1, :config2 => 2)
  #
  # Basically if you pass a symbol it will look for that file in the configs directory of your rails app,
  # if you are using this in rails. If you pass a string it should be an absolute path to your settings file.
  # Then you can pass a hash, and it just allows you to access the hash via methods.
  def initialize(hash_or_file = self.class.source, section = nil, key_trail = '')
    # raise RedisNotPresent.new if self.class.redis_key && ENV['REDIS_URL'].nil?

    case hash_or_file
    when nil
      raise Errno::ENOENT, "No file specified as Configlogic source"
    when Hash
      self.replace hash_or_file
    else
      file_contents = open(hash_or_file).read
      hash = file_contents.empty? ? {} : parse_yaml_content(file_contents)
      if self.class.namespace
        hash = hash[self.class.namespace] or return missing_key("Missing setting '#{self.class.namespace}' in #{hash_or_file}")
      end
      self.replace hash
    end

    @section = section || self.class.source  # so end of error says "in application.yml"
    @key_trail = key_trail
    create_accessors!
  end

  # Called for dynamically-defined keys, and also the first key deferenced at the top-level, if load! is not used.
  # Otherwise, create_accessors! (called by new) will have created actual methods for each key.
  def method_missing(name, *args, &block)
    key = name.to_s
    return missing_key("Missing setting '#{key}' in #{@section}") unless has_key? key
    value = fetch(key)
    create_accessor_for(key)
    value.is_a?(Hash) ? self.class.new(value, "'#{key}' section in #{@section}", "#{@key_trail}.#{key}") : value
  end

  def [](key)
    fetch(key.to_s, nil)
  end

  def []=(key,val)
    # Setting[:key][:key2] = 'value' for dynamic settings
    val = self.class.new(val, @section, "#{@key_trail}.#{key}") if val.is_a? Hash
    store(key.to_s, val)
    create_accessor_for(key, val)
  end

  # Returns an instance of a Hash object
  def to_hash
    Hash[self]
  end

  # This handles naming collisions with Sinatra/Vlad/Capistrano. Since these use a set()
  # helper that defines methods in Object, ANY method_missing ANYWHERE picks up the Vlad/Sinatra
  # settings!  So settings.deploy_to title actually calls Object.deploy_to (from set :deploy_to, "host"),
  # rather than the app_yml['deploy_to'] hash.  Jeezus.
  def create_accessors!
    self.each do |key,val|
      create_accessor_for(key)
    end
  end

  # Use instance_eval/class_eval because they're actually more efficient than define_method{}
  # http://stackoverflow.com/questions/185947/ruby-definemethod-vs-def
  # http://bmorearty.wordpress.com/2009/01/09/fun-with-rubys-instance_eval-and-class_eval/
  def create_accessor_for(key, val=nil)
    return unless key.to_s =~ /^\w+$/  # could have "some-setting:" which blows up eval
    instance_variable_set("@#{key}", val)

    self.class.class_eval <<-EndEval
      def #{key}
        return @#{key} if @#{key}
        return missing_key("Missing setting '#{key}' in #{@section}") unless has_key? '#{key}'
        value = fetch('#{key}')
        @#{key} = if value.is_a?(Hash)
          self.class.new(value, "'#{key}' section in #{@section}", "#{@key_trail}.#{key}")
        elsif value.is_a?(Array) && value.all?{|v| v.is_a? Hash}
          value.map{|v| self.class.new(v)}
        else
          Proc.new{find_key("#{@key_trail}", "#{key}", value)}
        end
      end
    EndEval
  end

  def find_key(trail, key, value)
    if self.class.cache_values_to_redis
      final_key_for_db_fetch = "#{trail}.#{key}"[1..-1] 
      cache_key = "config-#{self.class.redis_key.call}-#{final_key_for_db_fetch}"
      Rails.cache.fetch(cache_key, expires_in: 24.hours) do
        p "updating cache => #{cache_key}"
        final_value(final_key_for_db_fetch, value)
      end
    else
      final_value(final_key_for_db_fetch, value)
    end
  end

  def get_value_from_db?
    self.class.get_value_from_db && self.class.config_class.constantize && !self.class.config_class_column.blank?
  end

  def final_value(final_key, value)
    if get_value_from_db?
      db_key = final_key.split(".").map{|a| "'#{a}'"}.join("->").sub(/.*\K->/, '->>')
      db_key = "#{self.class.config_class_column}->#{db_key}"
      self.class.config_class.constantize.pluck(Arel.sql(db_key)).first
    else
      value
    end
  end

  def symbolize_keys

    inject({}) do |memo, tuple|

      k = (tuple.first.to_sym rescue tuple.first) || tuple.first

      v = k.is_a?(Symbol) ? send(k) : tuple.last # make sure the value is accessed the same way Settings.foo.bar works

      memo[k] = v && v.respond_to?(:symbolize_keys) ? v.symbolize_keys : v #recurse for nested hashes

      memo
    end

  end

  def missing_key(msg)
    return nil if self.class.suppress_errors

    raise MissingSetting, msg
  end

  private

  def parse_yaml_content(file_content)
    YAML.load(ERB.new(file_content).result, aliases: true).to_hash
  rescue ArgumentError
    YAML.load(ERB.new(file_content).result).to_hash
  end
end
