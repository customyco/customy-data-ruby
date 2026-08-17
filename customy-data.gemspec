require_relative "lib/customy/data"

Gem::Specification.new do |spec|
  spec.name = "customy-data"
  spec.version = Customy::Data::VERSION
  spec.authors = ["Customy"]
  spec.email = ["hello@customy.ai"]
  spec.summary = "Governed customer data collection SDK for Customy Data"
  spec.homepage = "https://github.com/customyco/customy-data-ruby"
  spec.metadata["source_code_uri"] = "https://github.com/customyco/customy-data-ruby"
  spec.license = "MIT"
  spec.required_ruby_version = Gem::Requirement.new(">= 2.6")
  spec.files = Dir["lib/**/*.rb", "README.md"]
  spec.require_paths = ["lib"]
end
