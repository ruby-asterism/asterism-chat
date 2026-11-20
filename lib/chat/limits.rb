module Chat
  # The daily limit: posts per device. A day is the local date of the
  # process (TZ). After a restart the posts of the day are counted again
  # from the log (the "post" records).
  class Limits
    def initialize(cfg, log, clock: -> { Time.now })
      @cfg = cfg
      @clock = clock
      @lock = Mutex.new
      @day = nil
      @count = Hash.new(0)
      roll
      log.records.each { @count[_1["device"]] += 1 if _1["ev"] == "post" }
    end

    def max = @cfg.limit("posts_per_device_per_day")

    def roll
      d = @clock.call.strftime("%Y-%m-%d")
      return if d == @day
      @day = d
      @count.clear
    end

    def used(device) = @lock.synchronize { roll; @count[device] }
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

    def count(device) = @lock.synchronize { roll; @count[device] += 1 }
  end
end
