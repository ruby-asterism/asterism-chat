# asterism-chat

A chat host for Family mruby devices over [Asterism](https://github.com/ruby-asterism/asterism).
It keeps the rooms its settings name, numbers the messages of each room, tells the devices of
every new message and keeps the last messages of every room on disk, so that a device opened
later reads what it missed. The devices are the members of an Asterism network you trust;
which ones may come in is decided by the router's roles (and, on a plain TCP router, by the
`devices` setting).

Status: 0.2.0: text and stamps (small pictures the users draw), and a container for a server
next to an Asterism console ([docs/install.md](docs/install.md)).

## Running

```
bundle install
bundle exec exe/asterism-chat --router tcp/127.0.0.1:7447 --node chat
bundle exec exe/asterism-chat status        # 0: up with the room exposed
```

With an Asterism console's certificate (an mTLS router): `credentials = "chat.tar"` in the
settings (the router then comes from the certificate). On a server, as a container next to the
console: [docs/install.md](docs/install.md) and `deploy/vps/`.

SIGTERM (and Ctrl-C): new posts are refused with `stopping`, the status file says so, the gem
exits.

## Settings

Options, then the environment, then the file (`--config`, or `ASTERISM_CHAT_CONFIG`), then the
defaults. `config/chat.toml.example` shows every key.

| Environment | Setting | Default |
|---|---|---|
| `ASTERISM_CHAT_ROUTER` | `network.router` (empty: the certificate's) | `tcp/127.0.0.1:7447` |
| `ASTERISM_CHAT_CREDENTIALS` | `network.credentials` | (none) |
| `ASTERISM_CHAT_NODE` | `network.node` | `chat` |
| `ASTERISM_CHAT_DEVICES` | `network.devices` (comma or space separated) | `*` |
| `ASTERISM_CHAT_NAME` | `network.name` | `Chat` |
| `ASTERISM_CHAT_ROOMS` | the rooms, `id:title,id2:title2` | `lobby:Lobby` |
| `ASTERISM_CHAT_HISTORY` | `limits.history` (messages kept per room) | 500 |
| `ASTERISM_CHAT_TEXT_MAX` | `limits.text_max` (characters) | 200 |
| `ASTERISM_CHAT_NAME_MAX` | `limits.name_max` (characters) | 8 |
| `ASTERISM_CHAT_PER_DAY` | `limits.posts_per_device_per_day` (a stamp counts as a post) | 300 |
| `ASTERISM_CHAT_STAMPS_MAX` | `stamps.max_count` (pictures kept) | 2000 |
| `ASTERISM_CHAT_STAMPS_BYTES` | `stamps.max_bytes` (bytes of all the pictures kept) | 16777216 (16 MB) |
| `ASTERISM_CHAT_STAMPS_PER_DAY` | `stamps.per_device_per_day` (new pictures a device may put a day) | 30 |
| `ASTERISM_CHAT_STAMP_BINARY` | `stamps.binary` (`stamp_get` sends a picture as a MessagePack `str` or `bin`) | `str` |
| `ASTERISM_CHAT_LOG_DIR` | `store.log_dir` | `~/.local/share/asterism-chat/log` |
| `ASTERISM_CHAT_STATE_DIR` | `store.state_dir` | `~/.local/share/asterism-chat/state` |

## On the network

The gem is the application `chat` on its node, with the object `room` and the topic `news`.

| Method | Argument | Answer |
|---|---|---|
| `hello(info)` | `{"name" => display name (optional), "fw", "lang", "host"}` | `{"ok", "proto" => 1, "host", "name" (nil until set), "rooms", "text_max", "name_max", "fetch_max", "per_day", "used", "tz"}` |
| `rooms()` | | `{"rooms" => [{"id", "title", "last"}]}` (`last`: the room's newest number, 0 when empty) |
| `post(req)` | `{"room", "text" or "stamp" => sha256, "cid" (optional: the device's own id of this post)}` | `{"room", "n", "t"}` |
| `history(req)` | `{"room", "after" => n}` (the rest, oldest first), `{"room", "before" => n}` (going back) or `{"room"}` (the newest); `"max"` | `{"room", "msgs", "last", "first", "more"}` |
| `stamp_has(req)` | `{"sha"}` | `{"sha", "has"}` |
| `stamp_put(req)` | `{"sha", "png" => the picture's bytes (a str or a bin)}` | `{"sha", "bytes", "new"}` (`new` false: the host had it, nothing written) |
| `stamp_get(req)` | `{"sha", "as" => "str" or "bin" (optional: `stamps.binary`)}` | `{"sha", "png"}` |

`hello` also answers `"stamp_px" => 48` and `"stamp_bytes" => 8192`, the bounds of a picture.

A message is `{"n", "t", "node", "name", "text"}`: its number in the room (1, 2, ...), the host's
time (seconds since 1970), the device that posted it (the caller the router saw), its display
name then, and the text. A stamp's message has `"text" => ""` and `"stamp" => sha256` (a text
message has no `"stamp"`).

### Stamps

A stamp is a PNG of at most 48 x 48 pixels and 8 KB, named by the sha256 (64 lower-case hex
digits) of its bytes. To post one, a device posts `{"room", "stamp" => sha}`; when the host does
not have that picture the answer is `no_stamp`, and the device sends it with `stamp_put` and
posts again. A device that gets a message with a `stamp` it does not have fetches it with
`stamp_get` (and keeps it: the same picture never travels twice).

`stamp_put` checks the picture without decoding it: the PNG signature, the IHDR chunk (and its
CRC) first, width and height 1 to 48, no interlace, and a colour type and bit depth the devices
decode (grey or palette at 1, 2, 4 or 8 bits; RGB, grey+alpha or RGBA at 8 bits); then it
computes the sha256 of the bytes again and compares it with `sha`. The picture may come as a
MessagePack str or bin; `stamp_get` sends it as a str unless `as` or `stamps.binary` says bin.

The host keeps at most `stamps.max_count` pictures and `stamps.max_bytes` in all. When a new
one does not fit, the pictures no kept message points to (their messages left the history) go
first, the oldest first (the last time a picture was put or posted); a picture a kept message
points to is never dropped, and when the new one still does not fit it is refused
(`stamp_full`). A device may put `stamps.per_device_per_day` new pictures a day (one the host
already has does not count).

### Refusals

A refusal is `{"error" => kind, "message" => a sentence for the device}`, never an exception.

| Kind | When |
|---|---|
| `not_allowed` | the device is not in `devices` |
| `bad_request` | the request is malformed (not a Hash, `after` below 0, `cid` too long, `sha` / `stamp` not a sha256, text and stamp together, `as` not str or bin) |
| `no_room` | a room the settings do not name |
| `empty` | the text is empty without its control characters and spaces |
| `too_long` | over `text_max` characters (the sentence says the number) |
| `bad_name` | the display name is empty or over `name_max` characters |
| `no_name` | a post before the device set its display name |
| `limit` | the posts of the day are used up |
| `stopping` | the host is stopping (SIGTERM); reading still works |
| `no_stamp` | `post` or `stamp_get` of a picture the host does not have |
| `too_big` | `stamp_put` of a picture over 8 KB, or wider or higher than 48 |
| `bad_stamp` | `stamp_put` of something that is not a PNG the devices decode (see above) |
| `bad_sha` | `stamp_put` whose bytes do not have the sha256 given |
| `stamp_limit` | the new pictures of the day are used up |
| `stamp_full` | no room for the picture although every other picture kept is pointed to |

`news` carries `{"room" => id, "n" => number}` for every new message, not the text: a device
fetches the text with `history(after:)`. A device that missed a value (`info.lost`), or comes
back, asks `rooms` and catches up the same way.

## On disk

Under `state_dir`: `rooms/<id>.jsonl` (the kept messages, oldest first), `names.json`
(`{node => display name}`), `stamps/<sha256>.png` (the pictures) and `status.json`. A restart
reads them back (a picture whose sha256 differs from its name is left out). Under `log_dir`: one
JSONL file a day of what happened (hellos, names set, posts with their room, number and length
or stamp's sha, pictures put with their sha, size and device, refusals); the text of a message
and the pictures are not in it.

## Tests

`bundle exec rake test`: the unit tests and an end-to-end test against a local zenohd (docker
`eclipse/zenoh:1.10.1` on 127.0.0.1:17530, started and stopped by the task). `test/sender.rb`
is a device stand-in that can also be used by hand.

## License

MIT
