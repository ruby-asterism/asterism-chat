# asterism-chat

A chat host for Family mruby devices over [Asterism](https://github.com/ruby-asterism/asterism).
It keeps the rooms its settings name, numbers the messages of each room, tells the devices of
every new message and keeps the last messages of every room on disk, so that a device opened
later reads what it missed. The devices are the members of an Asterism network you trust;
which ones may come in is decided by the router's roles (and, on a plain TCP router, by the
`devices` setting).

Status: 0.1.0, text only. Stamps (pictures the users draw) come next.

## Running

```
bundle install
bundle exec exe/asterism-chat --router tcp/127.0.0.1:7447 --node chat
bundle exec exe/asterism-chat status        # 0: up with the room exposed
```

With an Asterism console's certificate (an mTLS router): `credentials = "chat.tar"` in the
settings (the router then comes from the certificate).

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
| `ASTERISM_CHAT_PER_DAY` | `limits.posts_per_device_per_day` | 300 |
| `ASTERISM_CHAT_LOG_DIR` | `store.log_dir` | `~/.local/share/asterism-chat/log` |
| `ASTERISM_CHAT_STATE_DIR` | `store.state_dir` | `~/.local/share/asterism-chat/state` |

## On the network

The gem is the application `chat` on its node, with the object `room` and the topic `news`.

| Method | Argument | Answer |
|---|---|---|
| `hello(info)` | `{"name" => display name (optional), "fw", "lang", "host"}` | `{"ok", "proto" => 1, "host", "name" (nil until set), "rooms", "text_max", "name_max", "fetch_max", "per_day", "used", "tz"}` |
| `rooms()` | | `{"rooms" => [{"id", "title", "last"}]}` (`last`: the room's newest number, 0 when empty) |
| `post(req)` | `{"room", "text", "cid" (optional: the device's own id of this post)}` | `{"room", "n", "t"}` |
| `history(req)` | `{"room", "after" => n}` (the rest, oldest first), `{"room", "before" => n}` (going back) or `{"room"}` (the newest); `"max"` | `{"room", "msgs", "last", "first", "more"}` |

A message is `{"n", "t", "node", "name", "text"}`: its number in the room (1, 2, ...), the host's
time (seconds since 1970), the device that posted it (the caller the router saw), its display
name then, and the text.

A refusal is `{"error" => kind, "message" => a sentence for the device}`, never an exception:
`not_allowed`, `bad_request`, `no_room`, `empty`, `too_long`, `bad_name`, `no_name`, `limit`,
`stopping`.

`news` carries `{"room" => id, "n" => number}` for every new message, not the text: a device
fetches the text with `history(after:)`. A device that missed a value (`info.lost`), or comes
back, asks `rooms` and catches up the same way.

## On disk

Under `state_dir`: `rooms/<id>.jsonl` (the kept messages, oldest first), `names.json`
(`{node => display name}`) and `status.json`. A restart reads them back. Under `log_dir`: one
JSONL file a day of what happened (hellos, names set, posts with their room, number and length,
refusals); the text of a message is not in it.

## Tests

`bundle exec rake test`: the unit tests and an end-to-end test against a local zenohd (docker
`eclipse/zenoh:1.10.1` on 127.0.0.1:17530, started and stopped by the task). `test/sender.rb`
is a device stand-in that can also be used by hand.

## License

MIT
