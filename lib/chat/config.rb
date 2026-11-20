require "tomlrb"

module Chat
  # The settings (chat.toml). Every key has a default; a file sets only what
  # it changes, the environment (ASTERISM_CHAT_*, ENV_KEYS) goes over the
  # file and the options of exe/asterism-chat over both.
  #
  # The rooms are the [[rooms]] tables of the file (id, title), or
  # ASTERISM_CHAT_ROOMS ("id:title,id2:title2"). A room's id is part of
  # what the devices send and of the file its history is kept in, so it is
  # short and plain (ROOM_ID).
  class Config
    class Error < StandardError; end

    ROOM_ID = /\A[a-z0-9][a-z0-9_-]{0,15}\z/

    # Environment variable => [section, key, kind]. An empty value is the
    # same as no variable, except ASTERISM_CHAT_ROUTER, where it means "the
    # router the credentials name".
    ENV_KEYS = {
      "ASTERISM_CHAT_ROUTER" => ["network", "router", :s],
      "ASTERISM_CHAT_CREDENTIALS" => ["network", "credentials", :s],
      "ASTERISM_CHAT_NODE" => ["network", "node", :s],
      "ASTERISM_CHAT_DEVICES" => ["network", "devices", :list],
      "ASTERISM_CHAT_NAME" => ["network", "name", :s],
      "ASTERISM_CHAT_ROOMS" => [nil, "rooms", :rooms],
      "ASTERISM_CHAT_HISTORY" => ["limits", "history", :i],
      "ASTERISM_CHAT_TEXT_MAX" => ["limits", "text_max", :i],
      "ASTERISM_CHAT_NAME_MAX" => ["limits", "name_max", :i],
      "ASTERISM_CHAT_PER_DAY" => ["limits", "posts_per_device_per_day", :i],
      "ASTERISM_CHAT_LOG_DIR" => ["store", "log_dir", :s],
      "ASTERISM_CHAT_STATE_DIR" => ["store", "state_dir", :s]
    }.freeze
    # The settings file when --config is not given.
    ENV_CONFIG = "ASTERISM_CHAT_CONFIG".freeze
    EMPTY_MEANS = { "ASTERISM_CHAT_ROUTER" => "" }.freeze
    DEFAULTS = {
      "network" => {
        "router" => "tcp/127.0.0.1:7447",
        "node" => "chat",
        "credentials" => "",           # an Asterism console's .tar (mTLS); empty: plain TCP
        "devices" => ["*"],            # node IDs that may use the rooms; "*" lets every node in
        "name" => "Chat"               # shown on the device
      },
      "rooms" => [{ "id" => "lobby", "title" => "Lobby" }],
      "limits" => {
        "history" => 500,              # messages kept per room (older ones are dropped)
        "text_max" => 200,             # characters of one message
        "name_max" => 12,              # characters of a display name
        "fetch_max" => 20,             # messages in one history answer
        "reply_bytes" => 12_000,       # bytes of the messages in one history answer
        "posts_per_device_per_day" => 300
      },
      "store" => {
        "log_dir" => "~/.local/share/asterism-chat/log",
        "state_dir" => "~/.local/share/asterism-chat/state" # the history, the names, the status
      }
    }.freeze

    attr_reader :data

    # options > environment > file > defaults. path nil: ASTERISM_CHAT_CONFIG
    # when it is set (env: ENV by default, a Hash in the tests).
    def self.load(path = nil, overrides = {}, env: ENV)
      path ||= env[ENV_CONFIG] unless env[ENV_CONFIG].to_s.empty?
      data = path ? Tomlrb.load_file(path) : {}
      cfg = new(deep_merge(deep_merge(deep_merge(DEFAULTS, data), from_env(env)), overrides))
      cfg.check!
      cfg
    rescue Errno::ENOENT, Tomlrb::ParseError => e
      raise Error, "#{path}: #{e.message}"
    end

    # The settings the environment gives, as a Hash shaped like the file.
    def self.from_env(env)
      out = {}
      ENV_KEYS.each do |name, (section, key, kind)|
        next unless env.key?(name)
        raw = env[name].to_s.strip
        next if raw.empty? && !EMPTY_MEANS.key?(name)
        value = raw.empty? ? EMPTY_MEANS[name] : env_value(name, raw, kind)
        if section
          (out[section] ||= {})[key] = value
        else
          out[key] = value
        end
      end
      out
    end

    def self.env_value(name, raw, kind)
      case kind
      when :s then raw
      when :list then raw.split(/[,\s]+/).reject(&:empty?)
      when :i then Integer(raw, 10)
      when :rooms
        raw.split(",").map(&:strip).reject(&:empty?).map do |r|
          id, title = r.split(":", 2)
          { "id" => id.to_s.strip, "title" => (title || id).to_s.strip }
        end
      end
    rescue ArgumentError, TypeError
      raise Error, "#{name}=#{raw.inspect} is not a whole number"
    end

    # Hashes merge key by key; anything else (an Array: the rooms, the
    # devices) is replaced whole.
    def self.deep_merge(a, b)
      a.merge(b) { |_, x, y| x.is_a?(Hash) && y.is_a?(Hash) ? deep_merge(x, y) : y }
    end

    def initialize(data)
      @data = data
    end

    def [](section) = @data.fetch(section)
    def dig(*keys) = @data.dig(*keys)

    def log_dir = File.expand_path(dig("store", "log_dir"))
    def state_dir = File.expand_path(dig("store", "state_dir"))

    def limit(key) = dig("limits", key).to_i

    # [{"id" => .., "title" => ..}, ...] in the order of the settings.
    def rooms = Array(@data["rooms"])

    def room_ids = rooms.map { _1["id"] }

    def device_allowed?(node)
      list = Array(dig("network", "devices"))
      list.include?("*") || list.include?(node)
    end

    # Raises Error on settings the gem cannot run with.
    def check!
      raise Error, "no rooms (give [[rooms]] tables or ASTERISM_CHAT_ROOMS)" if rooms.empty?
      seen = {}
      rooms.each do |r|
        raise Error, "a room is not a table: #{r.inspect}" unless r.is_a?(Hash)
        id = r["id"].to_s
        raise Error, "room id #{id.inspect}: a-z 0-9 _ - only, 1 to 16 characters" unless ROOM_ID.match?(id)
        raise Error, "room id #{id} twice" if seen[id]
        seen[id] = true
        r["title"] = id if r["title"].to_s.strip.empty?
      end
      %w[history text_max name_max fetch_max reply_bytes posts_per_device_per_day].each do |k|
        raise Error, "limits.#{k} must be a whole number above 0" unless dig("limits", k).is_a?(Integer) && limit(k).positive?
      end
      self
    end
  end
end
