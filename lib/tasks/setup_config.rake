desc 'Config load'
namespace :configlogic do
  task load: :environment do
    def update_all_clients(incoming_config, klass)
      apartment_klass = klass.apartment_identifier_class.constantize

      apartment_klass.all.each do |client|
        Apartment::Tenant.switch(client.send(klass.apartment_identifier_column)) do
          config = klass.config_class.constantize.first
          if config
            if incoming_config.to_json != config.config.to_json
              p "updating client #{client&.subdomain}"
              saved_config = config.send(klass.config_class_column)
              config.update(config: saved_config.deep_merge(incoming_config))
            end
          else
            p "creating #{client&.subdomain}"
            klass.config_class.constantize.create("#{klass.config_class_column}": incoming_config)
          end
        end
      end
    end
    
    def hash_equal?(hash1, hash2)
      array1 = hash1.to_a
      array2 = hash2.to_a
      (array1 - array2 | array2 - array1) == []
    end

    Dir.glob("#{Rails.root}/config/configsetting/*.yml") do |file| 
      file_name = File.basename(file, ".*")
      klass = "Vp#{file_name.classify}".constantize
      incoming_config = klass.new("config/configsetting/#{file_name}.yml")
      config = klass.config_class.constantize.first
      if config
        unless hash_equal?(incoming_config, config.config)
          p "updating public"
          saved_config = config.send(klass.config_class_column)
          update_all_clients(incoming_config, klass) if defined?(Apartment)
          config.update(config: saved_config.deep_merge(incoming_config))
        end
      else
        p "creating public"
        update_all_clients(incoming_config, klass) if defined?(Apartment)
        klass.config_class.constantize.create("#{klass.config_class_column}": incoming_config)
      end
    end
  end
end
