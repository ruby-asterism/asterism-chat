module Chat
  # The gem as one Asterism application "chat" with one object "room" and
  # one topic "news".
  #
  # Alone (exe/asterism-chat):  Chat::Server.new(cfg).run
  # Inside another program that already has a connection:
  #   server = Chat::Server.new(cfg)
  #   server.attach(net)        # exposes "room" and publishes "news" on it
  class Server
    APP = "chat".freeze
    OBJECT = "room".freeze
    TOPIC = "news".freeze
    NEWS_TYPE = "asterism-chat/news".freeze

    attr_reader :cfg, :store, :log, :limits, :room

    def initialize(cfg, clock: -> { Time.now })
      @cfg = cfg
      @log = Log.new(cfg.log_dir, clock: clock)
      @store = Store.new(cfg, clock: clock)
      @limits = Limits.new(cfg, @log, clock: clock)
      @room = Room.new(cfg, store: @store, log: @log, limits: @limits)
      @stop_q = Queue.new
      @since = Time.now
    end

    def attach(net)
      net.define_type(NEWS_TYPE, [["room", "str"], ["n", "int"]], desc: "a new message: its room and number")
      news = net.publish(TOPIC, type: NEWS_TYPE, desc: "the number of each new message (fetch it with room.history)")
      @room.on_post = ->(room, n) { news.put({ "room" => room, "n" => n }) }
      path = net.expose(OBJECT, @room, caller: :from, methods: Room::METHODS,
                                       doc: "Family mruby chat: rooms, posts and history over Asterism")
      net.status("version" => VERSION, "rooms" => @cfg.room_ids.size)
      @log.write(:start, path: path, rooms: @cfg.room_ids, devices: @cfg.dig("network", "devices"),
                         limits: @cfg["limits"], version: VERSION)
      path
    end

    def connect_args
      n = @cfg["network"]
      args = { app: APP }
      args[:node] = n["node"] unless n["node"].to_s.empty?
      args[:credentials] = File.expand_path(n["credentials"]) unless n["credentials"].to_s.empty?
      router = n["router"].to_s
      [router.empty? ? nil : router, args]
    end

    # Asks run to end (a signal's trap may call it: a Queue push only).
    def request_stop(why = "stop") = @stop_q << why

    # Connects, exposes the room and answers until request_stop (SIGTERM,
    # Ctrl-C) or the connection ends; writes the status file meanwhile.
    # On request_stop new posts are refused ("stopping"); a call is answered
    # at once, so there is nothing to wait for. Returns the exit code: 0
    # stopped as asked, 1 the connection ended.
    def run
      require "asterism"
      locator, args = connect_args
      code = 0
      Asterism.connect(locator, **args) do |net|
        @net = net
        @path = attach(net)
        @router = locator || "the credentials' router"
        warn "asterism-chat #{VERSION}: #{@path} on #{@router}"
        warn "asterism-chat: rooms #{@cfg.room_ids.join(' ')}, #{@cfg.limit('history')} messages kept a room, " \
             "#{@limits.max} posts a device a day"
        $stderr.flush
        net.start
        why = nil
        loop do
          write_status
          unless net.running?
            warn "asterism-chat: the connection ended (#{net.lost_reason || 'closed'})"
            code = 1
            break
          end
          why = @stop_q.pop(timeout: Status::EVERY)
          break if why
        end
        if why
          @room.close
          write_status(stopping: true)
          @log.write(:stop, why: why)
          warn "asterism-chat: #{why}: stopped"
          $stderr.flush
        end
      end
      code
    ensure
      write_status(stopped: true) if @path
    end

    def status_now(stopping: false, stopped: false)
      net = @net
      connected = false
      reconnecting = false
      exposed = false
      if net && !stopped
        begin
          reconnecting = net.reconnecting? ? true : false
          connected = net.connected? && !reconnecting ? true : false
          exposed = net.exposed.include?(OBJECT)
        rescue StandardError
          connected = false
        end
      end
      { "version" => VERSION, "pid" => Process.pid, "at" => Time.now.iso8601(3), "since" => @since.iso8601,
        "path" => @path, "router" => @router, "connected" => connected, "reconnecting" => reconnecting,
        "exposed" => exposed, "stopping" => stopping || stopped, "stopped" => stopped,
        "rooms" => @store.lasts, "posts_today" => @limits.posts_today }
    end

    def write_status(**kw)
      Status.write(Status.path(@cfg), status_now(**kw))
    rescue SystemCallError => e
      warn "asterism-chat: cannot write the status (#{e.message})"
    end

    def stop = request_stop("stop")
  end
end
