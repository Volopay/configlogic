# lib/railtie.rb
require 'configlogic'
require 'rails'

module MyGem
  class Railtie < Rails::Railtie
    railtie_name :configlogic

    rake_tasks do
      path = File.expand_path(__dir__)
      Dir.glob("#{path}/tasks/**/*.rake").each { |f| load f }
    end
  end
end
