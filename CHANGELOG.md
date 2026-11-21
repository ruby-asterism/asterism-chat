# Changelog

## 0.2.0 (not released)

Stamps, and a container for a server next to an Asterism console.

- Stamps: a post may carry `"stamp" => sha256` instead of text (`no_stamp` when the host does not
  have the picture). `stamp_has`, `stamp_put` and `stamp_get` move the pictures: PNG, at most
  48 x 48 and 8 KB, checked without decoding (signature, IHDR and its CRC, colour type and bit
  depth the devices decode, no interlace) and by the sha256 of the bytes. A picture may come as
  a MessagePack str or bin; it goes back as a str unless `as` or `stamps.binary` says bin.
- The pictures are kept in `state_dir/stamps/<sha>.png`: at most `stamps.max_count` (2000) and
  `stamps.max_bytes` (16 MB). When a new one does not fit, the ones no kept message points to go
  first, the oldest first; when it still does not fit it is refused (`stamp_full`).
- New pictures per device per day (`stamps.per_device_per_day`, 30), counted again from the
  records after a restart. A stamp counts as a post in the posts of the day.
- New refusals: `no_stamp`, `too_big`, `bad_stamp`, `bad_sha`, `stamp_limit`, `stamp_full`.
- `hello` also answers `stamp_px` (48) and `stamp_bytes` (8192).
- The records hold a picture's sha, size and device, never its bytes.
- `deploy/vps/`: the Dockerfile (`ruby:3.4.13-slim`), the compose files, `env.example`,
  `update.sh` and `credentials/`; docs/install.md with the console's roles `chat-host` and
  `chat`; the image `ghcr.io/ruby-asterism/asterism-chat` built for each tag `v<version>` by
  `.github/workflows/image.yml` (amd64).
- `test/sender.rb`: `send_stamp`, `stamp_put` (as a str or a bin), `stamp_get`; by hand,
  `/stamp FILE.png` and `--save DIR`.

## 0.1.0 (not released)

The first cut: text only.

- The application `chat` with the object `room` (`hello`, `rooms`, `post`, `history`) and the
  topic `news` (`{"room", "n"}` for every new message; the text is fetched with `history`).
- Rooms from the settings (`[[rooms]]` or `ASTERISM_CHAT_ROOMS`), numbered per room from 1.
- Display names per device (the caller the router saw), kept with each message as it was then.
- The last `limits.history` messages of every room and the names on disk; a restart reads them
  back and the numbers go on.
- Refusals as `{"error", "message"}`: `not_allowed`, `bad_request`, `no_room`, `empty`,
  `too_long`, `bad_name`, `no_name`, `limit`, `stopping`.
- A post sent again with the same `cid` gets the number it already got.
- Posts per device per day, counted again from the records after a restart.
- JSONL records without the text of the messages, `asterism-chat status`, SIGTERM.
