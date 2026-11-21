require "msgpack"
require "digest"

module Chat
  # The object a device calls: <node>/chat/room (fmruby-core
  # doc/asterism_chat/report/c0.md 1). Every method gets the caller's node
  # ID (caller: :from), answers at once and returns a Hash; a refusal is a
  # Hash with "error" (a kind) and "message" (a sentence the device shows),
  # never an exception.
  #
  # A new message is told on the topic <node>/chat/news as {"room" => id,
  # "n" => number}: the number only, the device fetches the text with
  # history (on_post is given that by the server).
  #
  # Stamps (c0.md 3.3): a post may carry "stamp" => the sha256 of a picture
  # instead of text. When the host does not have that picture the post is
  # refused with "no_stamp"; the device then sends it with stamp_put and
  # posts again. A device fetches a picture it does not have with
  # stamp_get. A picture is a PNG of at most STAMP_PX x STAMP_PX and
  # STAMP_BYTES; it may come as a MessagePack str or bin.
  class Room
    METHODS = { hello: 1, rooms: 0, post: 1, history: 1, stamp_has: 1, stamp_put: 1, stamp_get: 1 }.freeze
    STAMP_PX = 48
    STAMP_BYTES = 8 * 1024
    PROTO = 1
    # Remembered per device, to answer a post sent again (after a timeout)
    # with the number it already got instead of posting it twice.
    CIDS = 32
    CID_MAX = 32 # bytes

    attr_accessor :on_post

    def initialize(cfg, store:, log:, limits:, stamps:)
      @cfg = cfg
      @stamps = stamps
      @store = store
      @log = log
      @limits = limits
      @lock = Mutex.new
      @cids = Hash.new { |h, k| h[k] = {} }
      @closing = false
      @on_post = nil
    end

    # No more posts (the gem is stopping); reading still works.
    def close = @closing = true
    def closing? = @closing

    def lim(key) = @cfg.limit(key)

    def allowed?(from) = @cfg.device_allowed?(from.to_s)

    def not_allowed(from, what)
      @log.write(:refused, device: from, call: what, why: "not_allowed")
      { "error" => "not_allowed", "message" => "この端末は、このチャットを使えるように登録されていません。" }
    end

    def bad(why) = { "error" => "bad_request", "message" => why }

    def str(v)
      v.is_a?(String) ? v.dup.force_encoding("UTF-8").scrub : nil
    end

    # Control characters out (a newline stays), CR LF as LF.
    def tidy(s) = s.gsub("\r\n", "\n").gsub(/[\x00-\x09\x0b-\x1f\x7f]/, "")

    def room_list
      lasts = @store.lasts
      @cfg.rooms.map { |r| { "id" => r["id"], "title" => r["title"], "last" => lasts[r["id"]] } }
    end

    # info: {"name" => display name (optional: absent keeps the one the
    # host has), "fw", "lang", "host"}.
    def hello(info, from:)
      return not_allowed(from, "hello") unless allowed?(from)
      info = {} unless info.is_a?(Hash)
      if info.key?("name")
        name, why = check_name(info["name"])
        return why if why
        @log.write(:name, device: from, name: name) if @store.set_name(from, name)
      end
      @log.write(:hello, device: from, info: info.reject { |k, _| k == "name" })
      { "ok" => true, "proto" => PROTO, "host" => @cfg.dig("network", "name"), "name" => @store.name(from),
        "rooms" => room_list, "text_max" => lim("text_max"), "name_max" => lim("name_max"),
        "fetch_max" => lim("fetch_max"), "per_day" => @limits.max, "used" => @limits.used(from),
        "tz" => @store.now.utc_offset, "stamp_px" => STAMP_PX, "stamp_bytes" => STAMP_BYTES }
    end

    # [name, nil] or [nil, error Hash]
    def check_name(v)
      s = str(v)
      return [nil, bad("name is not a String")] unless s
      s = tidy(s).delete("\n").strip
      max = lim("name_max")
      return [nil, { "error" => "bad_name", "message" => "表示名を入れてください。" }] if s.empty?
      if s.length > max
        return [nil, { "error" => "bad_name", "message" => "表示名は #{max} 文字までです。" }]
      end
      [s, nil]
    end

    def rooms(from:)
      return not_allowed(from, "rooms") unless allowed?(from)
      { "rooms" => room_list }
    end

    # req: {"room" => id, "text" => text or "stamp" => sha256 (one of the
    # two), "cid" => the device's own id of this post (optional, CID_MAX
    # bytes)}. Returns {"room", "n", "t"}.
    def post(req, from:)
      return not_allowed(from, "post") unless allowed?(from)
      return bad("the request is not a Hash") unless req.is_a?(Hash)
      room = req["room"].to_s
      return no_room(from, room) unless @store.room?(room) && @cfg.room_ids.include?(room)
      cid = str(req["cid"])
      return bad("cid over #{CID_MAX} bytes") if cid && cid.bytesize > CID_MAX
      if cid && (done = @lock.synchronize { @cids[from][cid] })
        return done.dup
      end
      stamp = nil
      if req["stamp"].nil?
        text = str(req["text"])
        return bad("text is not a String") unless text
        text = tidy(text).strip
        return { "error" => "empty", "message" => "送る文がありません。" } if text.empty?
        max = lim("text_max")
        if text.length > max
          @log.write(:refused, device: from, call: "post", why: "too_long", chars: text.length)
          return { "error" => "too_long", "message" => "長すぎます (#{max} 文字まで)。" }
        end
      else
        stamp = sha_of(req["stamp"])
        return bad("stamp is not a sha256 (64 hex digits)") unless stamp
        t = str(req["text"])
        return bad("text and stamp together (send one of them)") if t && !tidy(t).strip.empty?
        text = ""
        return no_stamp(from, stamp, "post") unless @stamps.has?(stamp)
      end
      name = @store.name(from)
      return { "error" => "no_name", "message" => "先に表示名を決めてください。" } unless name
      if @closing
        @log.write(:refused, device: from, call: "post", why: "stopping")
        return { "error" => "stopping", "message" => "チャットホストが止まるところです。少し待ってからもう一度送ってください。" }
      end
      if (refusal = @limits.refuse(from))
        @log.write(:refused, device: from, call: "post", why: "limit")
        return refusal
      end
      @limits.count(from)
      m = @store.append(room, from, name, text, stamp: stamp)
      if stamp
        @stamps.touch(stamp)
        @log.write(:post, device: from, room: room, n: m["n"], stamp: stamp)
      else
        @log.write(:post, device: from, room: room, n: m["n"], chars: text.length)
      end
      out = { "room" => room, "n" => m["n"], "t" => m["t"] }
      @lock.synchronize do
        seen = @cids[from]
        seen[cid] = out.dup if cid
        seen.shift while seen.size > CIDS
      end
      tell(room, m["n"])
      out
    end

    def no_room(from, room)
      @log.write(:refused, device: from, call: "room", why: "no_room", room: room)
      { "error" => "no_room", "message" => "その部屋はありません。" }
    end

    # --- stamps ---

    # The sha256 as 64 lower-case hex digits, or nil.
    def sha_of(v)
      s = str(v)&.downcase
      s if s && Stamps::SHA.match?(s)
    end

    # [sha, nil] or [nil, error Hash] from a stamp request's "sha".
    def stamp_req(req, from, call)
      return [nil, not_allowed(from, call)] unless allowed?(from)
      return [nil, bad("the request is not a Hash")] unless req.is_a?(Hash)
      sha = sha_of(req["sha"])
      return [nil, bad("sha is not a sha256 (64 hex digits)")] unless sha
      [sha, nil]
    end

    def no_stamp(from, sha, call)
      @log.write(:refused, device: from, call: call, why: "no_stamp", sha: sha)
      { "error" => "no_stamp", "message" => "その絵はチャットホストにありません。" }
    end

    # req: {"sha"}. Returns {"sha", "has" => whether the host has it}.
    def stamp_has(req, from:)
      sha, why = stamp_req(req, from, "stamp_has")
      return why if why
      { "sha" => sha, "has" => @stamps.has?(sha) }
    end

    # req: {"sha", "png" => the picture's bytes (a str or a bin)}. Checked
    # without decoding (Png), its sha256 computed again from the bytes.
    # Returns {"sha", "bytes", "new" => false when the host had it}.
    def stamp_put(req, from:)
      sha, why = stamp_req(req, from, "stamp_put")
      return why if why
      png = req["png"]
      return bad("png is not a String") unless png.is_a?(String)
      png = png.b
      if @closing
        @log.write(:refused, device: from, call: "stamp_put", why: "stopping")
        return { "error" => "stopping", "message" => "チャットホストが止まるところです。少し待ってからもう一度送ってください。" }
      end
      if png.bytesize > STAMP_BYTES
        return stamp_refused(from, sha, png, "too_big", "絵が大きすぎます (#{STAMP_BYTES / 1024} KB まで)。")
      end
      begin
        w, h = Png.size(png)
      rescue Png::Bad => e
        return stamp_refused(from, sha, png, "bad_stamp", "この絵はスタンプにできません (PNG の絵だけです)。", e.message)
      end
      if w > STAMP_PX || h > STAMP_PX
        return stamp_refused(from, sha, png, "too_big", "絵が大きすぎます (#{STAMP_PX}x#{STAMP_PX} まで)。", "#{w}x#{h}")
      end
      if Digest::SHA256.hexdigest(png) != sha
        return stamp_refused(from, sha, png, "bad_sha", "絵が途中で変わりました。もう一度送ってください。")
      end
      return { "sha" => sha, "bytes" => png.bytesize, "new" => false } if @stamps.has?(sha)
      if (refusal = @limits.refuse_stamp(from))
        @log.write(:refused, device: from, call: "stamp_put", why: "stamp_limit", sha: sha)
        return refusal
      end
      kept, dropped = @stamps.put(sha, png)
      case kept
      when :old
        { "sha" => sha, "bytes" => png.bytesize, "new" => false }
      when :full
        stamp_refused(from, sha, png, "stamp_full", "チャットホストの絵の置き場がいっぱいです。家の人に知らせてください。")
      else
        @limits.count_stamp(from)
        @log.write(:stamp, device: from, sha: sha, bytes: png.bytesize, w: w, h: h, new: true,
                           dropped: dropped.size)
        { "sha" => sha, "bytes" => png.bytesize, "new" => true }
      end
    end

    def stamp_refused(from, sha, png, kind, message, detail = nil)
      @log.write(:refused, device: from, call: "stamp_put", why: kind, sha: sha, bytes: png.bytesize,
                           **(detail ? { detail: detail } : {}))
      { "error" => kind, "message" => message }
    end

    # req: {"sha", "as" => "str" or "bin" (optional: stamps.binary)}.
    # Returns {"sha", "png" => the picture's bytes}.
    def stamp_get(req, from:)
      sha, why = stamp_req(req, from, "stamp_get")
      return why if why
      as = req["as"].nil? ? @cfg.dig("stamps", "binary") : str(req["as"])
      return bad("as is one of #{Config::BINARY.join(', ')}") unless Config::BINARY.include?(as)
      png = @stamps.read(sha)
      return no_stamp(from, sha, "stamp_get") unless png
      png = png.dup.force_encoding(Encoding::UTF_8) if as == "str"
      { "sha" => sha, "png" => png }
    end

    def tell(room, n)
      @on_post&.call(room, n)
    rescue StandardError => e
      warn "asterism-chat: could not tell #{room} #{n} (#{e.class}: #{e.message})"
    end

    # req: {"room" => id, and one of "after" => n (the messages after n,
    # oldest first: the rest of a room) or "before" => n (the ones just
    # before n: going back); neither: the newest; "max" => at most this many
    # (fetch_max at most)}. The answer also stops at reply_bytes, so that it
    # stays well under what a device receives in one answer.
    # Returns {"room", "msgs" => [message, ...] oldest first, "last" => the
    # room's newest number, "first" => its oldest kept (nil when empty),
    # "more" => whether there are more in the direction asked}.
    def history(req, from:)
      return not_allowed(from, "history") unless allowed?(from)
      return bad("the request is not a Hash") unless req.is_a?(Hash)
      room = req["room"].to_s
      return no_room(from, room) unless @store.room?(room) && @cfg.room_ids.include?(room)
      max = lim("fetch_max")
      max = req["max"] if req["max"].is_a?(Integer) && req["max"].between?(1, max)
      %w[after before].each do |k|
        return bad("#{k} is not a whole number") if req.key?(k) && !(req[k].is_a?(Integer) && req[k] >= 0)
      end
      range = @store.range(room)
      if req.key?("after")
        list = @store.after(room, req["after"], max + 1)
        more = list.size > max
        list = list.first(max)
        list, cut = fit(list, keep: :head)
        more ||= cut
      else
        list = @store.before(room, req["before"], max)
        list, = fit(list, keep: :tail)
        more = !list.empty? && list.first["n"] > range["first"].to_i
      end
      { "room" => room, "msgs" => list, "last" => range["last"], "first" => range["first"], "more" => more }
    end

    # The messages that fit reply_bytes (at least one), from the head (the
    # oldest: going forward) or the tail (the newest: going back).
    # [list, whether some were left out]
    def fit(list, keep:)
      budget = lim("reply_bytes")
      out = []
      used = 0
      order = keep == :head ? list : list.reverse
      order.each do |m|
        b = MessagePack.pack(m).bytesize
        break if !out.empty? && used + b > budget
        out << m
        used += b
      end
      out.reverse! if keep == :tail
      [out, out.size < list.size]
    end
  end
end
