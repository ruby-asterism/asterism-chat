require "rake/testtask"

# The local router of the tests: a zenohd container of its own, on a port
# that is neither the sim's (7447), the regression tools' (174xx) nor
# asterism-tutor's tests' (17520).
ROUTER_NAME = ENV.fetch("CHAT_ROUTER_NAME", "asterism_chat_zenohd")
ROUTER_PORT = Integer(ENV.fetch("CHAT_ROUTER_PORT", "17530"))
ROUTER_IMAGE = "eclipse/zenoh:1.10.1"

def router_running?
  `docker ps --filter name=^/#{ROUTER_NAME}$ --format '{{.Names}}'`.strip == ROUTER_NAME
end

namespace :router do
  desc "Start the test router (docker #{ROUTER_NAME}, tcp/127.0.0.1:#{ROUTER_PORT})"
  task :up do
    next if router_running?
    sh "docker", "run", "-d", "--rm", "--name", ROUTER_NAME, "-p", "127.0.0.1:#{ROUTER_PORT}:7447",
       ROUTER_IMAGE, "--no-multicast-scouting", "--listen", "tcp/0.0.0.0:7447", out: File::NULL
    40.times do
      break if system("bash", "-c", "exec 3<>/dev/tcp/127.0.0.1/#{ROUTER_PORT}", err: File::NULL)
      sleep 0.25
    end
    sleep 0.5
  end

  desc "Stop the test router"
  task :down do
    sh "docker", "stop", ROUTER_NAME, out: File::NULL, err: File::NULL if router_running?
  end
end

Rake::TestTask.new(:unit) do |t|
  t.libs << "lib" << "test"
  t.test_files = FileList["test/test_*.rb"] - ["test/test_e2e.rb"]
  t.warning = false
end

Rake::TestTask.new(:e2e_only) do |t|
  t.libs << "lib" << "test"
  t.test_files = ["test/test_e2e.rb"]
  t.warning = false
end

desc "The end-to-end test against the local router (started and stopped here)"
task :e2e do
  started = !router_running?
  Rake::Task["router:up"].invoke
  ENV["CHAT_TEST_ROUTER"] = "tcp/127.0.0.1:#{ROUTER_PORT}"
  begin
    Rake::Task["e2e_only"].invoke
  ensure
    Rake::Task["router:down"].invoke if started && ENV["KEEP_ROUTER"].to_s.empty?
  end
end

desc "Everything: the unit tests and the end-to-end test"
task test: %i[unit e2e]

task default: :test
