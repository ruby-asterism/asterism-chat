require "json"
require "fileutils"
require "time"

module Chat
  # The record of what happened (JSONL, one file a day, never deleted by the
  # gem): starts and stops, hellos, names set, posts and refusals. A post's
  # record holds the room, the number and the length, not the text: the text
  # lives in the history only, which drops it after limits.history messages.
  class Log
    attr_reader :dir

    def initialize(dir, clock: -> { Time.now })
      @dir = dir
      @clock = clock
      @lock = Mutex.new
      FileUtils.mkdir_p(dir)
    end

    def path(time = @clock.call) = File.join(@dir, "chat-#{time.strftime('%Y-%m-%d')}.jsonl")

    def write(ev, **fields)
      now = @clock.call
      rec = { "t" => now.iso8601(3), "ev" => ev.to_s }.merge(clean(fields.transform_keys(&:to_s)))
      line = JSON.generate(rec)
      @lock.synchronize { File.open(path(now), "a") { _1.puts(line) } }
      rec
    end

    # The records of one day (for the limits after a restart, and for reading).
    def records(time = @clock.call)
      p = path(time)
      return [] unless File.exist?(p)
      File.readlines(p).filter_map { JSON.parse(_1) rescue nil }
    end

    def clean(v)
      case v
      when String then v.dup.force_encoding("UTF-8").scrub
      when Hash then v.to_h { |k, x| [k.to_s, clean(x)] }
      when Array then v.map { clean(_1) }
      else v
      end
    end
  end
end
