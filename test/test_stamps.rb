require_relative "test_helper"
require "msgpack"

# The stamps without a network: put, get, the checks of a picture, the
# bounds and the order of dropping, the daily limit, the record and a
# restart.
class TestStamps < Minitest::Test
  A = "fmruby-aaa001".freeze
  B = "fmruby-aaa002".freeze

  def setup
    @dir = Dir.mktmpdir("asterism-chat-stamps")
    @now = Time.local(2026, 11, 21, 10, 0, 0)
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def cfg(over = {})
    base = { "store" => { "log_dir" => "#{@dir}/log", "state_dir" => "#{@dir}/state" },
             "rooms" => [{ "id" => "lobby", "title" => "Lobby" }] }
    Chat::Config.load(nil, Chat::Config.deep_merge(base, over), env: {})
  end

  def parts(c = cfg)
    clock = -> { @now }
    log = Chat::Log.new(c.log_dir, clock: clock)
    store = Chat::Store.new(c, clock: clock)
    stamps = Chat::Stamps.new(c, referenced: -> { store.stamp_refs }, clock: clock)
    limits = Chat::Limits.new(c, log, clock: clock)
    room = Chat::Room.new(c, store: store, log: log, limits: limits, stamps: stamps)
    room.hello({ "name" => "A" }, from: A)
    room.hello({ "name" => "B" }, from: B)
    [room, stamps, log, limits, store]
  end

  def put(room, png, from: A, sha: TestPng.sha(png))
    @now += 1
    room.stamp_put({ "sha" => sha, "png" => png }, from: from)
  end

  def post(room, sha, from: A) = room.post({ "room" => "lobby", "stamp" => sha }, from: from)

  def test_put_get_and_post
    room, stamps = parts
    png = TestPng.make(32, 32, seed: 1)
    sha = TestPng.sha(png)
    assert_equal({ "sha" => sha, "has" => false }, room.stamp_has({ "sha" => sha }, from: A))
    r = post(room, sha)
    assert_equal "no_stamp", r["error"]
    assert_kind_of String, r["message"]
    assert_equal({ "sha" => sha, "bytes" => png.bytesize, "new" => true }, put(room, png))
    assert File.exist?(File.join(stamps.dir, "#{sha}.png"))
    assert room.stamp_has({ "sha" => sha.upcase }, from: B)["has"]
    got = room.stamp_get({ "sha" => sha }, from: B)
    assert_equal sha, got["sha"]
    assert_equal png, got["png"].b
    n = post(room, sha)["n"]
    assert_equal 1, n
    m = room.history({ "room" => "lobby" }, from: B)["msgs"].last
    assert_equal({ "n" => 1, "t" => @now.to_i, "node" => A, "name" => "A", "text" => "", "stamp" => sha }, m)
    # a text message has no "stamp"
    room.post({ "room" => "lobby", "text" => "hi" }, from: A)
    refute room.history({ "room" => "lobby" }, from: B)["msgs"].last.key?("stamp")
  end

  def test_post_refusals
    room, = parts
    png = TestPng.make(16, 16, seed: 2)
    put(room, png)
    sha = TestPng.sha(png)
    assert_equal "bad_request", post(room, "abc")["error"]
    assert_equal "bad_request", post(room, 12)["error"]
    r = room.post({ "room" => "lobby", "stamp" => sha, "text" => "and words" }, from: A)
    assert_equal "bad_request", r["error"]
    assert_equal 1, room.post({ "room" => "lobby", "stamp" => sha, "text" => " " }, from: A)["n"]
    assert_equal "no_name", post(room, sha, from: "fmruby-aaa003")["error"]
    # stamps count in the posts of the day like text
    room2, = parts(cfg({ "limits" => { "posts_per_device_per_day" => 1 } }))
    assert_equal "limit", post(room2, sha)["error"]
  end

  def test_second_put_is_not_written_again
    room, stamps, log, limits = parts
    png = TestPng.make(48, 48, seed: 3)
    sha = TestPng.sha(png)
    assert put(room, png)["new"]
    file = File.join(stamps.dir, "#{sha}.png")
    mtime = File.mtime(file)
    r = put(room, png, from: B)
    assert_equal false, r["new"]
    assert_equal mtime, File.mtime(file)
    assert_equal 1, log.records(@now).count { _1["ev"] == "stamp" }
    assert_equal 0, limits.stamps_used(B)
  end

  def test_picture_checks
    room, stamps = parts
    big = TestPng.make(16, 16, seed: 4, pad: 8 * 1024)
    assert_equal "too_big", put(room, big)["error"]
    assert_equal "too_big", put(room, TestPng.make(49, 10, seed: 5))["error"]
    assert_equal "too_big", put(room, TestPng.make(10, 49, seed: 5))["error"]
    not_png = "GIF89a".b + ("\x00" * 40).b
    assert_equal "bad_stamp", put(room, not_png)["error"]
    assert_equal "bad_stamp", put(room, TestPng.make(16, 16, seed: 6, interlace: 1))["error"]
    assert_equal "bad_stamp", put(room, TestPng.make(16, 16, seed: 6, ctype: 2, depth: 16))["error"]
    broken = TestPng.make(16, 16, seed: 7)
    broken.setbyte(20, 99) # the width inside IHDR, so its CRC no longer matches
    assert_equal "bad_stamp", put(room, broken)["error"]
    png = TestPng.make(16, 16, seed: 8)
    r = put(room, png, sha: TestPng.sha(png + "x"))
    assert_equal "bad_sha", r["error"]
    assert_equal "bad_request", room.stamp_put({ "sha" => "zz", "png" => png }, from: A)["error"]
    assert_equal "bad_request", room.stamp_put({ "sha" => TestPng.sha(png) }, from: A)["error"]
    assert_empty Dir.children(stamps.dir)
    # the kinds the devices decode
    [[0, 1], [0, 8], [3, 4], [2, 8], [4, 8], [6, 8]].each_with_index do |(ctype, depth), i|
      assert put(room, TestPng.make(24, 24, seed: 20 + i, ctype: ctype, depth: depth))["new"], "#{ctype}/#{depth}"
    end
  end

  def test_not_allowed_and_stopping
    room, = parts(cfg({ "network" => { "devices" => [A] } }))
    png = TestPng.make(16, 16, seed: 9)
    assert_equal "not_allowed", put(room, png, from: B)["error"]
    assert_equal "not_allowed", room.stamp_get({ "sha" => TestPng.sha(png) }, from: B)["error"]
    assert_equal "not_allowed", room.stamp_has({ "sha" => TestPng.sha(png) }, from: B)["error"]
    room.close
    assert_equal "stopping", put(room, png)["error"]
  end

  def test_str_or_bin_both_ways
    room, = parts
    png = TestPng.make(16, 16, seed: 10)
    sha = TestPng.sha(png)
    # as a device's str arrives (a UTF-8 String with any bytes)
    as_str = MessagePack.unpack(MessagePack.pack({ "png" => png.dup.force_encoding("UTF-8") }))["png"]
    assert_equal Encoding::UTF_8, as_str.encoding
    assert put(room, as_str, sha: sha)["new"]
    got = room.stamp_get({ "sha" => sha }, from: B)["png"]
    assert_equal Encoding::UTF_8, got.encoding # str by default
    assert_equal png, MessagePack.unpack(MessagePack.pack(got)).b
    bin = room.stamp_get({ "sha" => sha, "as" => "bin" }, from: B)["png"]
    assert_equal Encoding::BINARY, bin.encoding
    assert_includes [0xc4, 0xc5], MessagePack.pack(bin).getbyte(0)
    assert_includes [0xd9, 0xda], MessagePack.pack(got).getbyte(0)
    assert_equal "bad_request", room.stamp_get({ "sha" => sha, "as" => "hex" }, from: B)["error"]
    assert_equal "no_stamp", room.stamp_get({ "sha" => "0" * 64 }, from: B)["error"]
    # bin by the settings
    room2, = parts(cfg({ "stamps" => { "binary" => "bin" } }))
    assert_equal Encoding::BINARY, room2.stamp_get({ "sha" => sha }, from: B)["png"].encoding
    assert_raises(Chat::Config::Error) { cfg({ "stamps" => { "binary" => "hex" } }) }
  end

  def test_restart_keeps_pictures
    c = cfg
    room, = parts(c)
    png = TestPng.make(32, 32, seed: 11)
    sha = TestPng.sha(png)
    put(room, png)
    post(room, sha)
    File.write(File.join(@dir, "state", "stamps", "#{'f' * 64}.png"), "not that") # a file whose sha differs
    File.write(File.join(@dir, "state", "stamps", "#{'e' * 64}.png.tmp"), "cut short")
    room2, stamps2 = parts(c)
    assert_equal png, room2.stamp_get({ "sha" => sha }, from: B)["png"].b
    assert_equal({ "count" => 1, "bytes" => png.bytesize }, stamps2.totals)
    refute File.exist?(File.join(@dir, "state", "stamps", "#{'e' * 64}.png.tmp"))
    assert_equal "no_stamp", room2.stamp_get({ "sha" => "f" * 64 }, from: B)["error"]
  end

  def test_drops_the_oldest_not_pointed_to
    room, stamps = parts(cfg({ "stamps" => { "max_count" => 3 } }))
    pngs = (0..5).map { TestPng.make(16, 16, seed: 30 + _1) }
    shas = pngs.map { TestPng.sha(_1) }
    put(room, pngs[0])
    put(room, pngs[1])
    put(room, pngs[2])
    post(room, shas[0]) # 0 is pointed to (and the newest now)
    @now += 1
    put(room, pngs[3])  # over 3: 1 goes (the oldest no message points to)
    assert_equal [true, false, true, true], shas[0..3].map { stamps.has?(_1) }
    put(room, pngs[4])  # then 2
    assert_equal [true, false, false, true, true], shas[0..4].map { stamps.has?(_1) }
    post(room, shas[3])
    post(room, shas[4])
    r = put(room, pngs[5]) # all three are pointed to
    assert_equal "stamp_full", r["error"]
    assert_equal 3, stamps.totals["count"]
    refute stamps.has?(shas[5])
  end

  def test_history_drop_frees_a_picture
    room, stamps = parts(cfg({ "stamps" => { "max_count" => 1 }, "limits" => { "history" => 2 } }))
    a = TestPng.make(16, 16, seed: 40)
    b = TestPng.make(16, 16, seed: 41)
    put(room, a)
    post(room, TestPng.sha(a))
    assert_equal "stamp_full", put(room, b)["error"]
    2.times { room.post({ "room" => "lobby", "text" => "push it out" }, from: A) }
    assert put(room, b)["new"]
    refute stamps.has?(TestPng.sha(a))
  end

  def test_bytes_bound
    room, stamps = parts(cfg({ "stamps" => { "max_bytes" => 3000 } }))
    pngs = (0..2).map { TestPng.make(16, 16, seed: 50 + _1, pad: 1000) }
    pngs.each { assert put(room, _1)["new"] }
    assert_operator stamps.totals["bytes"], :<=, 3000
    refute stamps.has?(TestPng.sha(pngs[0]))
    assert stamps.has?(TestPng.sha(pngs[2]))
  end

  def test_settings_made_smaller_drop_at_start
    c = cfg
    room, = parts(c)
    pngs = (0..3).map { TestPng.make(16, 16, seed: 60 + _1) }
    pngs.each { put(room, _1) }
    post(room, TestPng.sha(pngs[0]))
    _, stamps2 = parts(cfg({ "stamps" => { "max_count" => 2 } }))
    assert_equal 2, stamps2.totals["count"]
    assert stamps2.has?(TestPng.sha(pngs[0]))
    assert stamps2.has?(TestPng.sha(pngs[3]))
  end

  def test_daily_new_pictures
    c = cfg({ "stamps" => { "per_device_per_day" => 2 } })
    room, = parts(c)
    pngs = (0..3).map { TestPng.make(16, 16, seed: 70 + _1) }
    assert put(room, pngs[0])["new"]
    assert put(room, pngs[1])["new"]
    r = put(room, pngs[2])
    assert_equal "stamp_limit", r["error"]
    assert_includes r["message"], "2"
    assert_equal false, put(room, pngs[0])["new"] # one the host has is fine
    assert put(room, pngs[2], from: B)["new"]    # another device
    room2, _, _, limits2 = parts(c)               # counted again after a restart
    assert_equal 2, limits2.stamps_used(A)
    assert_equal "stamp_limit", put(room2, pngs[3])["error"]
    @now += 86_400
    assert put(room2, pngs[3])["new"]
  end

  def test_record_has_no_picture
    room, _, log = parts
    png = TestPng.make(16, 16, seed: 80, pad: 200)
    sha = TestPng.sha(png)
    put(room, png)
    post(room, sha)
    put(room, TestPng.make(60, 60, seed: 81))
    recs = log.records(@now)
    st = recs.find { _1["ev"] == "stamp" }
    assert_equal [A, sha, png.bytesize, 16, 16, true], st.values_at("device", "sha", "bytes", "w", "h", "new")
    po = recs.find { _1["ev"] == "post" }
    assert_equal [A, "lobby", 1, sha], po.values_at("device", "room", "n", "stamp")
    refused = recs.find { _1["ev"] == "refused" && _1["why"] == "too_big" }
    assert_equal "60x60", refused["detail"]
    text = File.binread(log.path(@now))
    refute_includes text, "xxxxxxxxxx"
    refute_includes text, "PNG"
    refute_includes text, "png\""
  end
end
