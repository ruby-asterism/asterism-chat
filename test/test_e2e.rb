require_relative "test_helper"
require "asterism"
require "open3"
require_relative "sender"

# The gem as a process (exe/asterism-chat) on a local router, called by
# test/sender.rb the way a device will. `rake e2e` starts the router.
#
# Two gems: "chat-test" (rooms lobby and family, the devices listed) and
# "chat-small" (any device, small limits, restarted by a test).
class TestE2E < Minitest::Test
  ROUTER = ENV["CHAT_TEST_ROUTER"].to_s
  WORK = Dir.mktmpdir("asterism-chat-e2e")
  EXE = File.expand_path("../exe/asterism-chat", __dir__)
  MAIN = "chat-test/chat/room".freeze
  SMALL = "chat-small/chat/room".freeze

  CONFIGS = {
    "main" => <<~TOML,
      [network]
      router = "#{ROUTER}"
      node = "chat-test"
      devices = ["fmruby-aaa001", "fmruby-aaa002", "fmruby-aaa003"]
      name = "test chat"
      [[rooms]]
      id = "lobby"
      title = "Lobby"
      [[rooms]]
      id = "family"
      title = "家族"
      [store]
      log_dir = "#{WORK}/log_main"
      state_dir = "#{WORK}/state_main"
    TOML
    "small" => <<~TOML
      [network]
      router = "#{ROUTER}"
      node = "chat-small"
      [[rooms]]
      id = "lobby"
      [limits]
      history = 5
      fetch_max = 3
      text_max = 10
      posts_per_device_per_day = 12
      [store]
      log_dir = "#{WORK}/log_small"
      state_dir = "#{WORK}/state_small"
    TOML
  }.freeze

  def self.start(name)
    cfg = File.join(WORK, "#{name}.toml")
    File.write(cfg, CONFIGS.fetch(name))
    _in, out, wait = Open3.popen2e("bundle", "exec", "ruby", EXE, "--config", cfg)
    line = nil
    t = Time.now
    until (line = out.gets).nil? || line.include?("asterism-chat: rooms ")
      raise "#{name} did not start" if Time.now - t > 20
    end
    raise "#{name} ended: #{out.read}" if line.nil?
    Thread.new { out.each_line { |l| File.write(File.join(WORK, "#{name}.out"), l, mode: "a") } }
    @servers[name] = wait
  end

  def self.stop(name)
    w = @servers.delete(name)
    return unless w
    Process.kill("TERM", w.pid) rescue nil
    w.join(10)
    w.value
  end

  @servers = {}
  @nets = {}
  class << self
    attr_reader :servers, :nets
  end

  def self.setup_once
    return if @ready
    @ready = true
    return if ROUTER.empty?
    start("main")
    start("small")
    Minitest.after_run do
      @nets.each_value { _1.close rescue nil }
      @servers.keys.each { stop(_1) }
      FileUtils.rm_rf(WORK) if ENV["KEEP_LOGS"].to_s.empty?
    end
  end

  def setup
    skip "no router (run `rake e2e`)" if ROUTER.empty?
    self.class.setup_once
  end

  def net(node)
    self.class.nets[node] ||= Asterism.connect(ROUTER, node: node, app: "chat")
  end

  def sender(node, path = MAIN, listen: true) = Sender.new(net(node), path, timeout: 5.0, listen: listen)

  # --- two devices talk, a third one comes later ---

  def test_talk_and_catch_up
    a = sender("fmruby-aaa001")
    b = sender("fmruby-aaa002")
    ha = a.hello("Alice")
    assert ha["ok"]
    assert_equal 1, ha["proto"]
    assert_equal "test chat", ha["host"]
    assert_equal %w[lobby family], ha["rooms"].map { _1["id"] }
    assert_equal 200, ha["text_max"]
    assert b.hello("ボブ")["ok"]
    sleep 1.0 # the publisher learns of the new subscribers
    got_a = []
    got_b = []
    nums = []
    6.times do |i|
      s = i.even? ? a : b
      r = s.post("lobby", "msg #{i}")
      refute r["error"], r.inspect
      nums << r["n"]
      # each side is told, and fetches what came after what it has
      assert b.wait_news { _1["room"] == "lobby" && _1["n"] == r["n"] }, "b was not told of #{r['n']}"
      assert a.wait_news { _1["room"] == "lobby" && _1["n"] == r["n"] }, "a was not told of #{r['n']}"
      got_a.concat(a.catch_up("lobby"))
      got_b.concat(b.catch_up("lobby"))
    end
    assert_equal (1..6).to_a, nums
    assert_equal (1..6).to_a, got_a.map { _1["n"] }
    assert_equal got_a, got_b
    assert_equal ["Alice", "ボブ"] * 3, got_a.map { _1["name"] }
    assert_equal %w[fmruby-aaa001 fmruby-aaa002] * 3, got_a.map { _1["node"] }
    # another room has numbers of its own
    assert_equal 1, a.post("family", "hi")["n"]
    assert a.wait_news { _1["room"] == "family" }

    # a device that comes later reads the history
    c = sender("fmruby-aaa003", listen: false)
    c.hello("Carol")
    h = c.history("room" => "lobby", "max" => 4)
    assert_equal [3, 4, 5, 6], h["msgs"].map { _1["n"] }
    assert h["more"]
    h = c.history("room" => "lobby", "before" => 3)
    assert_equal [1, 2], h["msgs"].map { _1["n"] }
    refute h["more"]
    h = c.history("room" => "lobby", "after" => 4)
    assert_equal [5, 6], h["msgs"].map { _1["n"] }
    refute h["more"]
    assert_equal [["lobby", 6], ["family", 1]], c.rooms["rooms"].map { [_1["id"], _1["last"]] }
  end

  def test_refusals
    z = sender("fmruby-zzz999", listen: false)
    assert_equal "not_allowed", z.hello("Zed")["error"]
    assert_equal "not_allowed", z.post("lobby", "x")["error"]
    s = sender("fmruby-aab001", SMALL, listen: false)
    assert_equal "no_name", s.post("lobby", "x")["error"]
    assert s.hello("S")["ok"]
    assert_equal "no_room", s.post("nowhere", "x")["error"]
    assert_equal "no_room", s.history("room" => "nowhere")["error"]
    r = s.post("lobby", "12345678901")
    assert_equal "too_long", r["error"]
    assert_includes r["message"], "10"
    assert_equal "bad_name", s.hello("x" * 9)["error"]
  end

  def test_daily_limit
    s = sender("fmruby-aac001", SMALL, listen: false)
    s.hello("L")
    12.times { refute s.post("lobby", "m")["error"] }
    assert_equal "limit", s.post("lobby", "m")["error"]
    assert_equal 12, s.hello["used"]
  end

  # --- a restart keeps the history, the numbers and the names ---

  def test_restart
    s = sender("fmruby-aad001", SMALL, listen: false)
    s.hello("Dan")
    last = nil
    8.times { last = s.post("lobby", "r#{_1}")["n"] }
    before = s.history("room" => "lobby", "max" => 3)
    assert_equal 0, self.class.stop("small")
    self.class.nets.delete("fmruby-aad001")&.close
    self.class.start("small")
    s = sender("fmruby-aad001", SMALL, listen: false)
    assert_equal "Dan", s.hello["name"]
    after = s.history("room" => "lobby", "max" => 3)
    assert_equal before["msgs"], after["msgs"]
    assert_equal last, after["last"]
    assert_equal last - 4, after["first"] # history = 5: the older ones are gone
    old = s.history("room" => "lobby", "before" => after["first"] + 1)
    assert_equal [after["first"]], old["msgs"].map { _1["n"] }
    refute old["more"]
    assert_equal last + 1, s.post("lobby", "again")["n"]
    lines = File.readlines(File.join(WORK, "state_small", "rooms", "lobby.jsonl"))
    assert_operator lines.size, :<=, 5 + 16
    assert lines.all? { JSON.parse(_1)["n"] > last - 5 }
  end

  def test_status_command
    out, code = Open3.capture2e("bundle", "exec", "ruby", EXE, "status", "--config", File.join(WORK, "main.toml"))
    assert_equal 0, code.exitstatus, out
    assert_includes out, "up, joined to"
  end
end
