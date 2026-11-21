require "digest"
require "fileutils"

module Chat
  # The stamps' pictures: <state_dir>/stamps/<sha256>.png, one file each,
  # named by the sha256 of its bytes (a device sends the sha in a post, and
  # fetches the picture of a sha it does not have).
  #
  # Bounded by stamps.max_count pictures and stamps.max_bytes in all. When a
  # new picture does not fit, the ones no kept message points to (their
  # messages left the history) go first, the oldest first; "old" is the
  # last time a picture was put or posted (the file's mtime, so a restart
  # keeps the order). A picture some kept message points to is never
  # dropped; when the new one still does not fit, it is refused.
  #
  # The bytes are checked by Room (Png) before put; a restart checks every
  # file's sha256 again and leaves out (does not serve) one that differs.
  class Stamps
    SHA = /\A[0-9a-f]{64}\z/

    attr_reader :dir

    # referenced: a callable returning the shas the kept messages point to
    # (Store#stamp_refs).
    def initialize(cfg, referenced:, clock: -> { Time.now })
      @cfg = cfg
      @referenced = referenced
      @clock = clock
      @lock = Mutex.new
      @dir = File.join(cfg.state_dir, "stamps")
      FileUtils.mkdir_p(@dir)
      @index = {} # sha => {"bytes" => n, "t" => Float}
      load
    end

    def max_count = @cfg.dig("stamps", "max_count").to_i
    def max_bytes = @cfg.dig("stamps", "max_bytes").to_i

    def path(sha) = File.join(@dir, "#{sha}.png")

    def has?(sha) = @lock.synchronize { @index.key?(sha) }

    # {"count", "bytes"} of what is kept.
    def totals = @lock.synchronize { { "count" => @index.size, "bytes" => total } }

    # The picture's bytes (binary), or nil.
    def read(sha)
      @lock.synchronize do
        return nil unless @index.key?(sha)
        File.binread(path(sha))
      end
    rescue SystemCallError
      nil
    end

    # A post used the picture: it becomes the newest for the order of
    # dropping.
    def touch(sha)
      @lock.synchronize do
        e = @index[sha] or return
        t = @clock.call
        e["t"] = t.to_f
        File.utime(t, t, path(sha))
      end
    rescue SystemCallError
      nil
    end

    # Keeps a checked picture. Returns [:old] (already kept, nothing
    # written), [:new, dropped shas] or [:full] (it does not fit even after
    # dropping every picture no message points to; nothing changed).
    def put(sha, bytes)
      raise ArgumentError, "not a sha256: #{sha.inspect}" unless SHA.match?(sha)
      @lock.synchronize do
        return [:old] if @index.key?(sha)
        drop = plan_room(bytes.bytesize, 1)
        return [:full] unless drop
        drop.each { remove(_1) }
        tmp = "#{path(sha)}.tmp"
        File.binwrite(tmp, bytes)
        t = @clock.call
        File.utime(t, t, tmp)
        File.rename(tmp, path(sha))
        @index[sha] = { "bytes" => bytes.bytesize, "t" => t.to_f }
        [:new, drop]
      end
    end

    private

    def total = @index.sum { _2["bytes"] }

    # The shas to drop so that `count` more pictures of `bytes` fit, or nil
    # when they cannot.
    def plan_room(bytes, count)
      n = @index.size
      size = total
      return [] if n + count <= max_count && size + bytes <= max_bytes
      refs = @referenced.call
      drop = []
      @index.reject { |sha, _| refs.include?(sha) }.sort_by { |sha, e| [e["t"], sha] }.each do |sha, e|
        break if n + count <= max_count && size + bytes <= max_bytes
        drop << sha
        n -= 1
        size -= e["bytes"]
      end
      return nil unless n + count <= max_count && size + bytes <= max_bytes
      drop
    end

    def remove(sha)
      @index.delete(sha)
      File.delete(path(sha))
    rescue Errno::ENOENT
      nil
    end

    def load
      bad = 0
      Dir.children(@dir).each do |f|
        full = File.join(@dir, f)
        if f.end_with?(".tmp")
          File.delete(full) # a put cut short
          next
        end
        sha = f.delete_suffix(".png")
        next unless f.end_with?(".png") && SHA.match?(sha)
        bytes = File.binread(full)
        if Digest::SHA256.hexdigest(bytes) != sha
          bad += 1
          next
        end
        @index[sha] = { "bytes" => bytes.bytesize, "t" => File.mtime(full).to_f }
      end
      warn "asterism-chat: stamps: left out #{bad} file(s) whose sha256 differs" if bad.positive?
      # Settings made smaller since the last run: drop what no message
      # points to until the rest fits (what is pointed to stays even so).
      drop = plan_room(0, 0)
      drop ||= @index.reject { |sha, _| @referenced.call.include?(sha) }.keys
      drop.each { remove(_1) }
    end
  end
end
