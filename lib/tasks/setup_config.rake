desc 'Config load'
namespace :configlogic do
  task load: :environment do
    def update_all_clients(incoming_config)
      Client.all.each do |client|
        Apartment::Tenant.switch(client.tenant_id) do
          config = ClientConfig.first
          if config
            if incoming_config.to_json != config.config.to_json
              p "updating client #{client.subdomain}"
              config.update(config: config.config.deep_merge(incoming_config))
            end
          else
            p "creating #{client.subdomain}"
            ClientConfig.create(config: incoming_config)
          end
        end
      end
    end
    
    def hash_equal?(hash1, hash2)
      array1 = hash1.to_a
      array2 = hash2.to_a
      (array1 - array2 | array2 - array1) == []
    end

    incoming_config = VpConfig.new("config/vp_client_config.yml")
    config = ClientConfig.first
    if config
      unless hash_equal?(incoming_config, config.config)
        p "updating public"
        config.update(config: config.config.deep_merge(incoming_config))
        byebug
        update_all_clients(incoming_config)
      end
    else
      p "creating public"
      ClientConfig.create(config: incoming_config)
      update_all_clients(incoming_config)
    end
  end
end
