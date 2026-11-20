# Changelog

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
