# coding: utf-8

version = File.read(File.expand_path("COMPOSE_VERSION", __dir__)).strip
# update version
version_file = File.expand_path("./lib/version.rb", __dir__)
new_content = File.read(version_file).gsub(/".+"/, "\"#{version}\"")
File.open(version_file, "w") {|file| file.puts new_content }

Gem::Specification.new do |spec|
  spec.name          = "docker-compose-api"
  spec.version       = version
  spec.authors       = ["Mauricio S. Klein"]
  spec.email         = ["mauricio.klein.msk@gmail.com"]
  spec.summary       = %q{A simple ruby client for docker-compose api}
  spec.description   = %q{A simple ruby client for docker-compose api}
  spec.homepage      = "https://github.com/mauricioklein/docker-compose-api"
  spec.license       = "MIT"

  spec.files         = `git ls-files -z`.split("\x0")
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.test_files    = spec.files.grep(%r{^(test|spec|features)/})
  spec.require_paths = ["lib"]

  spec.add_dependency "docker-api", "~> 1.33"

  spec.add_development_dependency "bundler", "~> 1.7"
  spec.add_development_dependency "rspec", "~> 3.3"
  spec.add_development_dependency "simplecov", "~> 0.10"
  spec.add_development_dependency "byebug", "~> 9.0"
end
