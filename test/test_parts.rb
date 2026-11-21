require_relative "test_helper"

# The parts without a network: the settings, the store on disk, the room's
# answers and refusals, the daily limit and the status check.
class TestParts < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("asterism-chat-parts")
    @now = Time.local(2026, 11, 21, 10, 0, 0)
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def cfg(over = {}, env: {})
    base = { "store" => { "log_dir" => "#{@dir}/log", "state_dir" => "#{@dir}/state" },
             "rooms" => [{ "id" => "lobby", "title" => "Lobby" }, { "id" => "family", "title" => "家族" }] }
    Chat::Config.load(nil, Chat::Config.deep_merge(base, over), env: env)
  end

  def parts(c = cfg)
    clock = -> { @now }
    log = Chat::Log.new(c.log_dir, clock: clock)
    store = Chat::Store.new(c, clock: clock)
    stamps = Chat::Stamps.new(c, referenced: -> { store.stamp_refs }, clock: clock)
    limits = Chat::Limits.new(c, log, clock: clock)
    room = Chat::Room.new(c, store: store, log: log, limits: limits, stamps: stamps)
    [room, store, log, limits, stamps]
  end

  # --- settings ---

  def test_config_order
    path = File.join(@dir, "chat.toml")
    File.write(path, <<~TOML)
      [network]
      node = "from-file"
      [limits]
      history = 50
      [[rooms]]
      id = "a"
      title = "A"
      [[rooms]]
      id = "b"
    TOML
    c = Chat::Config.load(path, {}, env: { "ASTERISM_CHAT_HISTORY" => "70" })
    assert_equal "from-file", c.dig("network", "node")
    assert_equal 70, c.limit("history")
    assert_equal 200, c.limit("text_max")
    assert_equal [{ "id" => "a", "title" => "A" }, { "id" => "b", "title" => "b" }], c.rooms
    c = Chat::Config.load(path, { "network" => { "node" => "opt" } },
                          env: { "ASTERISM_CHAT_ROOMS" => "x:エックス, y", "ASTERISM_CHAT_DEVICES" => "fmruby-aaaaaa fmruby-bbbbbb" })
    assert_equal "opt", c.dig("network", "node")
    assert_equal %w[x y], c.room_ids
    assert_equal "エックス", c.rooms[0]["title"]
    assert c.device_allowed?("fmruby-aaaaaa")
    refute c.device_allowed?("fmruby-cccccc")
  end

  def test_config_refuses
    assert_raises(Chat::Config::Error) { Chat::Config.load(nil, {}, env: { "ASTERISM_CHAT_ROOMS" => "Bad/Room" }) }
    assert_raises(Chat::Config::Error) { Chat::Config.load(nil, {}, env: { "ASTERISM_CHAT_ROOMS" => "a,a" }) }
    assert_raises(Chat::Config::Error) { cfg({ "limits" => { "history" => 0 } }) }
    assert_raises(Chat::Config::Error) { cfg({}, env: { "ASTERISM_CHAT_PER_DAY" => "many" }) }
  end

  # --- the room ---

  def test_numbers_per_room
    room, = parts
    assert room.hello({ "name" => "Alice" }, from: "fmruby-aaa001")["ok"]
    assert_equal 1, room.post({ "room" => "lobby", "text" => "a" }, from: "fmruby-aaa001")["n"]
    assert_equal 2, room.post({ "room" => "lobby", "text" => "b" }, from: "fmruby-aaa001")["n"]
    assert_equal 1, room.post({ "room" => "family", "text" => "c" }, from: "fmruby-aaa001")["n"]
    r = room.rooms(from: "fmruby-aaa001")["rooms"]
    assert_equal [["lobby", 2], ["family", 1]], r.map { [_1["id"], _1["last"]] }
  end

  def test_refusals
    room, = parts(cfg({ "network" => { "devices" => ["fmruby-aaa001", "fmruby-aaa002"] },
                        "limits" => { "text_max" => 10, "name_max" => 4, "posts_per_device_per_day" => 2 } }))
    a = "fmruby-aaa001"
    assert_equal "not_allowed", room.hello({}, from: "fmruby-zzz999")["error"]
    assert_equal "not_allowed", room.post({ "room" => "lobby", "text" => "x" }, from: "fmruby-zzz999")["error"]
    assert_equal "not_allowed", room.history({ "room" => "lobby" }, from: "fmruby-zzz999")["error"]
    assert_equal "bad_name", room.hello({ "name" => "あいうえお" }, from: a)["error"]
    assert_equal "bad_name", room.hello({ "name" => "  " }, from: a)["error"]
    assert_equal "no_name", room.post({ "room" => "lobby", "text" => "x" }, from: a)["error"]
    assert_nil room.hello({ "name" => "あいうえ" }, from: a)["error"]
    assert_equal "no_room", room.post({ "room" => "nowhere", "text" => "x" }, from: a)["error"]
    assert_equal "no_room", room.history({ "room" => "nowhere" }, from: a)["error"]
    assert_equal "too_long", room.post({ "room" => "lobby", "text" => "あ" * 11 }, from: a)["error"]
    assert_equal "empty", room.post({ "room" => "lobby", "text" => " \n " }, from: a)["error"]
    assert_equal "bad_request", room.post("lobby", from: a)["error"]
    assert_equal 1, room.post({ "room" => "lobby", "text" => "あ" * 10 }, from: a)["n"]
    assert_equal 2, room.post({ "room" => "lobby", "text" => "x" }, from: a)["n"]
    r = room.post({ "room" => "lobby", "text" => "x" }, from: a)
    assert_equal "limit", r["error"]
    assert_kind_of String, r["message"]
    room.close
    room.hello({ "name" => "b" }, from: "fmruby-aaa002")
    assert_equal "stopping", room.post({ "room" => "lobby", "text" => "x" }, from: "fmruby-aaa002")["error"]
  end

  def test_cid_answers_again
    room, = parts
    room.hello({ "name" => "A" }, from: "fmruby-aaa001")
    one = room.post({ "room" => "lobby", "text" => "x", "cid" => "c1" }, from: "fmruby-aaa001")
    again = room.post({ "room" => "lobby", "text" => "x", "cid" => "c1" }, from: "fmruby-aaa001")
    assert_equal one, again
    assert_equal 2, room.post({ "room" => "lobby", "text" => "x", "cid" => "c2" }, from: "fmruby-aaa001")["n"]
  end

  def test_history_directions
    room, = parts(cfg({ "limits" => { "fetch_max" => 3 } }))
    room.hello({ "name" => "A" }, from: "fmruby-aaa001")
    7.times { room.post({ "room" => "lobby", "text" => "m#{_1 + 1}" }, from: "fmruby-aaa001") }
    h = room.history({ "room" => "lobby" }, from: "fmruby-aaa001")
    assert_equal [5, 6, 7], h["msgs"].map { _1["n"] }
    assert h["more"]
    assert_equal 7, h["last"]
    assert_equal 1, h["first"]
    m = h["msgs"][0]
    assert_equal %w[n t node name text], m.keys
    assert_equal ["fmruby-aaa001", "A", "m5", @now.to_i], [m["node"], m["name"], m["text"], m["t"]]
    h = room.history({ "room" => "lobby", "before" => 5 }, from: "fmruby-aaa001")
    assert_equal [2, 3, 4], h["msgs"].map { _1["n"] }
    assert h["more"]
    h = room.history({ "room" => "lobby", "before" => 2 }, from: "fmruby-aaa001")
    assert_equal [1], h["msgs"].map { _1["n"] }
    refute h["more"]
    h = room.history({ "room" => "lobby", "after" => 2 }, from: "fmruby-aaa001")
    assert_equal [3, 4, 5], h["msgs"].map { _1["n"] }
    assert h["more"]
    h = room.history({ "room" => "lobby", "after" => 5, "max" => 1 }, from: "fmruby-aaa001")
    assert_equal [6], h["msgs"].map { _1["n"] }
    h = room.history({ "room" => "lobby", "after" => 6 }, from: "fmruby-aaa001")
    assert_equal [7], h["msgs"].map { _1["n"] }
    refute h["more"]
    assert_equal "bad_request", room.history({ "room" => "lobby", "after" => -1 }, from: "fmruby-aaa001")["error"]
  end

  def test_history_stops_at_reply_bytes
    room, = parts(cfg({ "limits" => { "fetch_max" => 20, "reply_bytes" => 2000 } }))
    room.hello({ "name" => "A" }, from: "fmruby-aaa001")
    10.times { room.post({ "room" => "lobby", "text" => "あ" * 200 }, from: "fmruby-aaa001") }
    h = room.history({ "room" => "lobby", "after" => 0 }, from: "fmruby-aaa001")
    assert_equal [1, 2, 3], h["msgs"].map { _1["n"] } # 600 B of text each
    assert h["more"]
    h = room.history({ "room" => "lobby" }, from: "fmruby-aaa001")
    assert_equal [8, 9, 10], h["msgs"].map { _1["n"] }
    assert h["more"]
  end

  # --- the store on disk ---

  def test_restart_keeps_history_numbers_and_names
    c = cfg({ "limits" => { "history" => 5 } })
    room, store = parts(c)
    room.hello({ "name" => "Alice" }, from: "fmruby-aaa001")
    40.times { room.post({ "room" => "lobby", "text" => "m#{_1 + 1}" }, from: "fmruby-aaa001") }
    lines = File.readlines(store.room_file("lobby")).size
    assert_operator lines, :<=, 5 + store.margin
    room2, = parts(c)
    assert_equal 5, File.readlines(store.room_file("lobby")).size # read back trimmed
    h = room2.history({ "room" => "lobby" }, from: "fmruby-aaa001")
    assert_equal (36..40).to_a, h["msgs"].map { _1["n"] }
    assert_equal 36, h["first"]
    assert_equal "Alice", room2.hello({}, from: "fmruby-aaa001")["name"]
    assert_equal 41, room2.post({ "room" => "lobby", "text" => "next" }, from: "fmruby-aaa001")["n"]
    assert_equal 1, room2.post({ "room" => "family", "text" => "first" }, from: "fmruby-aaa001")["n"]
  end

  def test_broken_last_line
    c = cfg
    room, store = parts(c)
    room.hello({ "name" => "A" }, from: "fmruby-aaa001")
    3.times { room.post({ "room" => "lobby", "text" => "m" }, from: "fmruby-aaa001") }
    File.write(store.room_file("lobby"), "{\"n\":4,\"t\":1,\"no", mode: "a")
    room2, = parts(c)
    assert_equal 4, room2.post({ "room" => "lobby", "text" => "x" }, from: "fmruby-aaa001")["n"]
  end

  def test_limit_counts_again_after_restart
    c = cfg({ "limits" => { "posts_per_device_per_day" => 3 } })
    room, = parts(c)
    room.hello({ "name" => "A" }, from: "fmruby-aaa001")
    2.times { room.post({ "room" => "lobby", "text" => "m" }, from: "fmruby-aaa001") }
    room2, _, _, limits = parts(c)
    assert_equal 2, limits.used("fmruby-aaa001")
    assert room2.post({ "room" => "lobby", "text" => "m" }, from: "fmruby-aaa001")["n"]
    assert_equal "limit", room2.post({ "room" => "lobby", "text" => "m" }, from: "fmruby-aaa001")["error"]
    @now += 86_400
    assert room2.post({ "room" => "lobby", "text" => "m" }, from: "fmruby-aaa001")["n"]
  end

  def test_log_has_no_text
    room, _, log = parts
    room.hello({ "name" => "A" }, from: "fmruby-aaa001")
    room.post({ "room" => "lobby", "text" => "secret words" }, from: "fmruby-aaa001")
    recs = log.records(@now)
    post = recs.find { _1["ev"] == "post" }
    assert_equal ["fmruby-aaa001", "lobby", 1, 12], post.values_at("device", "room", "n", "chars")
    refute_includes File.read(log.path(@now)), "secret words"
  end

  # --- the status ---

  def test_status_check
    now = Time.now
    base = { "version" => Chat::VERSION, "path" => "chat/chat/room", "at" => now.iso8601(3), "connected" => true,
             "exposed" => true, "router" => "tcp/192.0.2.1:7447", "rooms" => { "lobby" => 3 }, "posts_today" => 3 }
    assert_equal 0, Chat::Status.check(base, now: now)[0]
    assert_equal 1, Chat::Status.check(base.merge("connected" => false), now: now)[0]
    assert_equal 1, Chat::Status.check(base.merge("stopping" => true), now: now)[0]
    assert_equal 2, Chat::Status.check(base, now: now + 60)[0]
    assert_equal 2, Chat::Status.check(nil)[0]
  end
end
