# The test's stand-in for a device: calls <node>/chat/room and listens to
# <node>/chat/news the way the device's chat app will (fmruby-core
# doc/asterism_chat/report/c0.md 1), from CRuby.
#
# As a library (the tests):
#   s = Sender.new(net)                       # finds */chat/room, listens to the news
#   s.hello("Alice")
#   s.post("lobby", "hello")                  # => {"room", "n", "t"}
#   s.wait_news { |v| v["room"] == "lobby" }  # => {"room" => "lobby", "n" => 3}
#   s.catch_up("lobby")                       # the messages after the last one seen
#   s.send_stamp("lobby", File.binread("a.png")) # post a stamp; puts the picture first when asked
#   s.stamp_get(sha)                          # => {"sha", "png"}
#
# As a command (by hand, against a running gem):
#   ruby test/sender.rb --router tcp/127.0.0.1:17530 --node fmruby-test01 --name Alice lobby
# reads lines from stdin and posts them; prints every new message of the room.
# A line "/stamp FILE.png" posts that picture as a stamp; a stamp that comes
# in is fetched and saved as <sha>.png in --save DIR (when given).
require "asterism"
require "json"
require "digest"

class Sender
  attr_reader :proxy, :path, :news, :seen

  def initialize(net, path = nil, timeout: 5.0, listen: true)
    @net = net
    @path = path || find
    @proxy = net[@path, timeout: timeout]
    @news = Queue.new
    @seen = Hash.new(0)        # room => the newest number taken
    return unless listen
    host = @path.split("/").first
    net.subscribe("#{host}/chat/news") { |v, _info| @news << v }
    net.start unless net.running?
  end

  def find(wait = 5.0)
    t = Time.now
    loop do
      @net.poll unless @net.running?
      found = @net.each("*/chat/room")
      return found[0].asterism_path unless found.empty?
      raise "no */chat/room on the network" if Time.now - t > wait
      sleep 0.1
    end
  end

  def hello(name = nil)
    info = { "fw" => "3.1.0", "lang" => "ja", "host" => "cruby" }
    info["name"] = name if name
    @proxy.hello(info)
  end

  def rooms = @proxy.rooms
  def post(room, text, cid: nil) = @proxy.post({ "room" => room, "text" => text }.merge(cid ? { "cid" => cid } : {}))
  def history(req) = @proxy.history(req)

  # --- stamps ---

  # as: :bin sends the picture as a MessagePack bin, :str as a str (how a
  # device's String may come).
  def stamp_put(png, as: :bin, sha: Digest::SHA256.hexdigest(png.b))
    data = as == :str ? png.b.force_encoding(Encoding::UTF_8) : png.b
    @proxy.stamp_put({ "sha" => sha, "png" => data })
  end

  def stamp_has(sha) = @proxy.stamp_has({ "sha" => sha })

  def stamp_get(sha, as: nil)
    @proxy.stamp_get({ "sha" => sha }.merge(as ? { "as" => as.to_s } : {}))
  end

  # Posts a stamp the way a device does: the post first; when the host
  # does not have the picture (no_stamp), it is put and the post sent
  # again. Returns the post's answer (or the put's refusal).
  def send_stamp(room, png, cid: nil, as: :bin)
    sha = Digest::SHA256.hexdigest(png.b)
    req = { "room" => room, "stamp" => sha }.merge(cid ? { "cid" => cid } : {})
    r = @proxy.post(req)
    return r unless r["error"] == "no_stamp"
    put = stamp_put(png, as: as, sha: sha)
    return put if put["error"]
    @proxy.post(req)
  end

  # The next news value the block accepts (all when no block), or nil.
  def wait_news(timeout: 5.0)
    limit = Time.now + timeout
    loop do
      left = limit - Time.now
      return nil if left <= 0
      v = @news.pop(timeout: left)
      return nil if v.nil?
      return v if !block_given? || yield(v)
    end
  end

  # Every message after the last one taken, in as many calls as it needs.
  def catch_up(room)
    out = []
    loop do
      r = history("room" => room, "after" => @seen[room])
      raise "history: #{r}" if r["error"]
      out.concat(r["msgs"])
      @seen[room] = r["msgs"].last["n"] unless r["msgs"].empty?
      break unless r["more"]
    end
    out
  end
end

if $PROGRAM_NAME == __FILE__
  require "optparse"
  o = { router: nil, node: nil, app: "chat", name: nil }
  OptionParser.new do |p|
    p.on("--router L") { o[:router] = _1 }
    p.on("--node ID") { o[:node] = _1 }
    p.on("--credentials TAR", "a console's .tar (mTLS)") { o[:credentials] = _1 }
    p.on("--app NAME", "this application's name (default chat, the device's)") { o[:app] = _1 }
    p.on("--name NAME", "the display name to set") { o[:name] = _1 }
    p.on("--save DIR", "save the stamps that come in there") { o[:save] = _1 }
  end.parse!
  room = ARGV.first or abort("usage: sender.rb [options] ROOM")
  args = { app: o[:app] }
  if o[:credentials]
    args[:credentials] = o[:credentials]
    args[:node] = o[:node] if o[:node]
  else
    o[:router] ||= "tcp/127.0.0.1:17530"
    args[:node] = o[:node] || "fmruby-test01"
  end
  Asterism.connect(o[:router], **args) do |net|
    s = Sender.new(net)
    puts JSON.generate(s.hello(o[:name]))
    show = lambda do |m|
      body = m["text"]
      if m["stamp"]
        body = "[stamp #{m['stamp'][0, 12]}]"
        if o[:save]
          g = s.stamp_get(m["stamp"])
          if g["png"]
            File.binwrite(File.join(o[:save], "#{m['stamp']}.png"), g["png"].b)
          else
            body += " (#{g['error']})"
          end
        end
      end
      puts "#{m['n']} #{Time.at(m['t']).strftime('%H:%M')} #{m['name']}: #{body}"
    end
    r = s.history("room" => room)
    r["msgs"].each(&show)
    s.seen[room] = r["last"]
    Thread.new do
      loop do
        v = s.news.pop
        s.catch_up(room).each(&show) if v["room"] == room
      end
    end
    $stdin.each_line do |line|
      line = line.chomp
      a = if line.start_with?("/stamp ")
            s.send_stamp(room, File.binread(line.delete_prefix("/stamp ").strip))
          else
            s.post(room, line)
          end
      warn JSON.generate(a) if a["error"]
    end
  end
end
