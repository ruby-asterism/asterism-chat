require_relative "lib/chat/version"

Gem::Specification.new do |s|
  s.name = "asterism-chat"
  s.version = Chat::VERSION
  s.summary = "A chat host for Family mruby devices over Asterism: rooms, history and display names"
  s.description = "Runs next to an Asterism router. Family mruby devices call it (over Asterism) to " \
                  "post in the rooms its settings name and to read the history; it numbers the " \
                  "messages of each room, tells the devices of a new number on a topic and keeps " \
                  "the last messages of every room on disk."
  s.authors = ["Katsuhiko Kageyama"]
  s.license = "MIT"
  s.required_ruby_version = ">= 3.4"
  s.files = Dir["lib/**/*.rb", "exe/*", "config/*.example", "README.md", "README.ja.md", "LICENSE", "CHANGELOG.md"]
  s.require_paths = ["lib"]
  s.bindir = "exe"
  s.executables = ["asterism-chat"]
  s.add_dependency "asterism", ">= 0.14"
  s.add_dependency "msgpack", "~> 1.7"
  s.add_dependency "tomlrb", "~> 2.0"
end
