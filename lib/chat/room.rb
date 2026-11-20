require "msgpack"

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
  class Room
    METHODS = { hello: 1, rooms: 0, post: 1, history: 1 }.freeze
    PROTO = 1
    # Remembered per device, to answer a post sent again (after a timeout)
    # with the number it already got instead of posting it twice.
    CIDS = 32
    CID_MAX = 32 # bytes

    attr_accessor :on_post

    def initialize(cfg, store:, log:, limits:)
      @cfg = cfg
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
        "tz" => @store.now.utc_offset }
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

    # req: {"room" => id, "text" => text, "cid" => the device's own id of
    # this post (optional, CID_MAX bytes)}. Returns {"room", "n", "t"}.
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
      text = str(req["text"])
      return bad("text is not a String") unless text
      text = tidy(text).strip
      return { "error" => "empty", "message" => "送る文がありません。" } if text.empty?
      max = lim("text_max")
      if text.length > max
        @log.write(:refused, device: from, call: "post", why: "too_long", chars: text.length)
        return { "error" => "too_long", "message" => "長すぎます (#{max} 文字まで)。" }
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
      m = @store.append(room, from, name, text)
      @log.write(:post, device: from, room: room, n: m["n"], chars: text.length)
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
