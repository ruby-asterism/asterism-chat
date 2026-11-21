module Chat
  # The daily limits per device: posts, and new stamps' pictures put (a
  # picture the host already has is not counted). A day is the local date
  # of the process (TZ). After a restart the day is counted again from the
  # log (the "post" records, and the "stamp" records with "new").
  class Limits
    def initialize(cfg, log, clock: -> { Time.now })
      @cfg = cfg
      @clock = clock
      @lock = Mutex.new
      @day = nil
      @count = Hash.new(0)
      @stamps = Hash.new(0)
      roll
      log.records.each do |r|
        @count[r["device"]] += 1 if r["ev"] == "post"
        @stamps[r["device"]] += 1 if r["ev"] == "stamp" && r["new"]
      end
    end

    def max = @cfg.limit("posts_per_device_per_day")
    def stamps_max = @cfg.dig("stamps", "per_device_per_day").to_i

    def roll
      d = @clock.call.strftime("%Y-%m-%d")
      return if d == @day
      @day = d
      @count.clear
      @stamps.clear
    end

    def used(device) = @lock.synchronize { roll; @count[device] }
    def stamps_used(device) = @lock.synchronize { roll; @stamps[device] }
    # All devices' posts of the day (for the status).
    def posts_today = @lock.synchronize { roll; @count.values.sum }

    # nil when the device may post now, else the refusal (an error Hash).
    def refuse(device)
      @lock.synchronize do
        roll
        next nil if @count[device] < max
        { "error" => "limit", "message" => "今日送れる数 (#{max} 回) を使い切りました。また明日送れます。" }
      end
    end

    # nil when the device may put a new picture now, else the refusal.
    def refuse_stamp(device)
      @lock.synchronize do
        roll
        next nil if @stamps[device] < stamps_max
        { "error" => "stamp_limit",
          "message" => "今日送れる新しい絵の数 (#{stamps_max} 枚) を使い切りました。また明日送れます。" }
      end
    end

    def count(device) = @lock.synchronize { roll; @count[device] += 1 }
    def count_stamp(device) = @lock.synchronize { roll; @stamps[device] += 1 }
  end
end
