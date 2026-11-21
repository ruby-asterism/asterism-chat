require "json"
require "fileutils"

module Chat
  # What the gem keeps: the messages of every room and the display name of
  # every device. One Mutex; every method returns copies or plain values, so
  # the calls (on Asterism's receiving thread) and anything else never share
  # a Hash being changed.
  #
  # On disk, under <state_dir>:
  #   rooms/<id>.jsonl   one message a line, oldest first; a post appends a
  #                      line. When the file holds more than the kept
  #                      messages by a margin, it is written again with the
  #                      kept ones only (whole, then renamed over the old).
  #   names.json         {node => display name}, written whole on a change.
  # A restart reads both back: the history, the next number of each room
  # (the last kept message's + 1) and the names. A room no longer in the
  # settings keeps its file but is not served; a new one starts at 1.
  #
  # A message: {"n" => number in the room (1, 2, ...), "t" => the host's
  # time (seconds since 1970), "node" => the device, "name" => its display
  # name when it posted, "text" => the text}. A stamp's message has
  # "text" => "" and "stamp" => the sha256 of its picture (Stamps).
  class Store
    attr_reader :dir

    def initialize(cfg, clock: -> { Time.now })
      @cfg = cfg
      @clock = clock
      @lock = Mutex.new
      @keep = cfg.limit("history")
      @dir = cfg.state_dir
      @room_dir = File.join(@dir, "rooms")
      FileUtils.mkdir_p(@room_dir)
      @rooms = {}   # id => {"msgs" => [...], "last" => n, "lines" => lines in the file}
      @names = {}
      cfg.room_ids.each { load_room(_1) }
      load_names
    end

    def now = @clock.call

    def room?(id) = @rooms.key?(id)

    # --- names ---

    def name(node) = @lock.synchronize { @names[node] }

    def set_name(node, name)
      @lock.synchronize do
        return false if @names[node] == name
        @names[node] = name
        write_whole(File.join(@dir, "names.json"), JSON.generate(@names))
        true
      end
    end

    # --- messages ---

    # Adds a message to a room; returns it (a copy).
    def append(room, node, name, text, stamp: nil)
      @lock.synchronize do
        r = @rooms.fetch(room)
        m = { "n" => r["last"] + 1, "t" => now.to_i, "node" => node, "name" => name, "text" => text }
        m["stamp"] = stamp if stamp
        File.open(room_file(room), "a") { _1.puts(JSON.generate(m)) }
        r["lines"] += 1
        r["last"] = m["n"]
        r["msgs"] << m
        r["msgs"].shift while r["msgs"].size > @keep
        compact(room) if r["lines"] > @keep + margin
        m.dup
      end
    end

    # {"last" => newest number (0: none yet), "first" => oldest kept (nil: none)}
    def range(room)
      @lock.synchronize do
        r = @rooms.fetch(room)
        { "last" => r["last"], "first" => r["msgs"].first&.fetch("n") }
      end
    end

    # The shas of the stamps the kept messages of the served rooms point to
    # ({sha => true}).
    def stamp_refs
      @lock.synchronize do
        out = {}
        @rooms.each_value { |r| r["msgs"].each { |m| out[m["stamp"]] = true if m["stamp"] } }
        out
      end
    end

    # The newest number of every served room, {id => n}.
    def lasts = @lock.synchronize { @rooms.transform_values { _1["last"] } }

    # The kept messages with a number above `after`, oldest first, at most
    # max (copies).
    def after(room, after, max)
      @lock.synchronize do
        @rooms.fetch(room)["msgs"].select { _1["n"] > after }.first(max).map(&:dup)
      end
    end

    # The kept messages with a number below `before`, at most max, the
    # newest of them (oldest first). before nil: the newest of all.
    def before(room, before, max)
      @lock.synchronize do
        list = @rooms.fetch(room)["msgs"]
        list = list.select { _1["n"] < before } if before
        list.last(max).map(&:dup)
      end
    end

    # --- the files ---

    def room_file(id) = File.join(@room_dir, "#{id}.jsonl")

    # Written again once the file has this many lines over the kept ones,
    # so that a busy room does not rewrite its file on every post.
    def margin = [@keep / 4, 16].max

    def compact(id)
      r = @rooms[id]
      write_whole(room_file(id), r["msgs"].map { JSON.generate(_1) }.join("\n") + (r["msgs"].empty? ? "" : "\n"))
      r["lines"] = r["msgs"].size
    end

    # Written whole, then renamed over the old one: a restart sees the old
    # file or the new one, never half of one.
    def write_whole(path, text)
      tmp = "#{path}.tmp"
      File.write(tmp, text)
      File.rename(tmp, path)
    end

    def load_room(id)
      path = room_file(id)
      msgs = []
      lines = 0
      bad = 0
      if File.exist?(path)
        File.foreach(path) do |line|
          lines += 1
          m = JSON.parse(line) rescue nil
          if m.is_a?(Hash) && m["n"].is_a?(Integer) && (msgs.empty? || m["n"] > msgs.last["n"])
            msgs << m
          else
            bad += 1  # a line cut short by a crash, or out of order
          end
        end
      end
      warn "asterism-chat: room #{id}: skipped #{bad} broken line(s)" if bad.positive?
      last = msgs.empty? ? 0 : msgs.last["n"]
      @rooms[id] = { "msgs" => msgs.last(@keep), "last" => last, "lines" => lines }
      compact(id) if lines != @rooms[id]["msgs"].size
      File.delete("#{path}.tmp") if File.exist?("#{path}.tmp")
    end

    def load_names
      path = File.join(@dir, "names.json")
      return unless File.exist?(path)
      h = JSON.parse(File.read(path))
      @names = h.select { |k, v| k.is_a?(String) && v.is_a?(String) } if h.is_a?(Hash)
    rescue JSON::ParserError, SystemCallError => e
      warn "asterism-chat: cannot read names.json (#{e.class}); starting with no names"
    end
  end
end
