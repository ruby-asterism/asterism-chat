# The chat host on a server

asterism-chat (the rooms, the history and the stamps of Family mruby's
chat) as a container next to an Asterism console on a server (a VPS), so
that the devices' Chat app works without a PC running the gem. The devices
keep their usual router (the console's); only those with the console's
role `chat` reach the rooms. The console's installation comes first: its
`docs/install.md`, with its `deploy/vps` running as the compose project
`asterism`.

Names and addresses below are placeholders: `router.example.org` for the
console's router, `fmruby-aaaaaa` for a device, `/srv/asterism` for where
the checkouts are.

## 1. What runs

```
 devices (Chat, role "chat") --tls/router.example.org:7448, their own certificates--> zenohd
                                                                                         ^
 asterism-chat (project "asterism-chat")                                                 |
   one process -------------------------------TLS as chat (its own .tar) ---- tls/zenohd:7448
     exposes chat/chat/room                   (the console's network asterism_router)
     puts chat/chat/news (the number of each new message)
   /state (its volume): log/    the records (JSONL, one file a day; never deleted, not backed up)
                        store/  rooms/<id>.jsonl (the history), names.json,
                                stamps/<sha>.png (the pictures), status.json
   /credentials (deploy/vps/credentials/, read-only): chat.tar
```

- A compose project of its own (`deploy/vps/docker-compose.yml`, project
  `asterism-chat`): the console's, the game host's and the AI host's
  `update.sh` never touch it. It uses the console's network
  `asterism_router` by name and publishes no port: nothing changes for
  nginx, the firewall or DNS.
- It holds no key but its certificate, and calls nothing outside the
  router.
- The history and the pictures are not in the console's daily backup
  (section 11).

## 2. What you need

- The console 0.4.0 or later running (`docker compose ps` in its
  `deploy/vps`); 0.4.2 or later to let users' browsers in (section 9).
- About 192 MB of free memory, 200 MB of disk for the image and up to
  about 20 MB for the state (16 MB of pictures at most, and the history:
  500 messages a room).
- git and Docker with compose v2.24 or later, as for the console.

## 3. The console's side

In the console (Admin > Relay):

1. **Roles > New role `chat-host`** (the chat host itself):
   - Read and write:
     ```
     asterism/${node}
     asterism/${node}/chat/**
     asterism/${node}/@profile
     asterism/${node}/chat/@profile
     asterism/${node}/chat/@status
     asterism/${node}/chat/@pubs
     ```
   - Read: none. Ask: none.
   - Watch: `asterism/**`
   - Not for browsers.
2. **Roles > New role `chat`** (the devices that may come in):
   - Read and write (the device's own Chat app, `chat`):
     ```
     asterism/${node}
     asterism/${node}/chat/**
     asterism/${node}/@profile
     asterism/${node}/chat/@profile
     asterism/${node}/chat/@status
     asterism/${node}/chat/@pubs
     ```
   - Read (the room's tokens, so the app finds `*/chat/room`, the answers
     to its calls, and the topic of new messages):
     ```
     asterism/*/chat/room
     asterism/*/chat/protocol/*
     asterism/*/chat/room/meta
     asterism/*/chat/room/call/${node}
     asterism/*/chat/news                 (*)
     ```
   - Ask (the calls, under the device's own name only):
     ```
     asterism/*/chat/room/meta
     asterism/*/chat/room/call/${node}
     ```
   - Watch: `asterism/**`
   - "Browsers have this role": off (the users' browsers get it one by one,
     section 9).
   A `**` does not match a chunk that starts with `@`, so each `@` line is
   needed as it is.
3. **The devices' rows** (e.g. `fmruby-aaaaaa`): Edit, tick `chat` next to
   the roles they have. Only those devices reach the rooms. For a user's
   browser (console 0.4.2 or later): section 9.
4. **Register**: kind `client`, name `chat`, role `chat-host`. Open it,
   "Issue a certificate", "Save all (.tar)": `chat.tar`.
5. Apply (the banner "Review and apply").

(*) The lines of both roles copy asterism-tutor's rows `tutor-host` and
`tutor` (which were tried on a console's router) with `tutor/helper` made
`chat/room` and the device's app `chat`. The one line with no counterpart
there is the topic `asterism/*/chat/news` (the device subscribes to
`*/chat/news`; a Read line allows declaring the subscriber and receiving
the values). These rows have not been tried on a console's router yet.

## 4. Get the files

Next to the console's checkout:

```
cd /srv/asterism
git clone <the asterism-chat repository> asterism-chat
cd asterism-chat/deploy/vps
cp env.example .env && chmod 600 .env
install -m 600 -o 1000 -g 1000 ~/chat.tar credentials/chat.tar     # sudo if you are not uid 1000
```

Copy `chat.tar` to the server as you would a private key (scp, then remove
the copy in your downloads). `credentials/` is never committed (its
`.gitignore`).

`.env` (env.example says what each line is):

- `ASTERISM_PROJECT=asterism` (the console's project).
- `ASTERISM_CHAT_CREDENTIALS=/credentials/chat.tar`. The router is
  `tls/zenohd:7448` on the console's network (`CHAT_ROUTER` changes it),
  not the public name in the `.tar`.
- `ASTERISM_CHAT_ROOMS=family:家族,games:ゲーム,friends:ともだち`: the
  rooms, in the order the devices show them, `id:title`. An id is
  `a-z 0-9 _ -`, up to 16 characters, and names the room's history file:
  changing a title keeps the history, changing an id starts a new room
  (the old one's file stays in the volume, not served).
- `ASTERISM_CHAT_DEVICES=fmruby-aaaaaa,...`: the same devices that have
  the role `chat`. The role decides who reaches the rooms; this list is
  the gem's own check on top (a device with the role but not in the list
  is told it is not registered).
- `ASTERISM_CHAT_NAME` (default `Chat`): the name the devices show for
  this host.
- The limits: `ASTERISM_CHAT_HISTORY` (500 messages kept a room),
  `ASTERISM_CHAT_TEXT_MAX` (200 characters), `ASTERISM_CHAT_NAME_MAX`
  (8 characters of a display name), `ASTERISM_CHAT_PER_DAY` (300 posts,
  text or stamp, a device a day).
- The stamps: `ASTERISM_CHAT_STAMPS_MAX` (2000 pictures),
  `ASTERISM_CHAT_STAMPS_BYTES` (16777216, 16 MB of pictures in all),
  `ASTERISM_CHAT_STAMPS_PER_DAY` (30 new pictures a device a day). When a
  new picture does not fit, the pictures no kept message points to go
  first, the oldest first; a picture a message in the history points to
  is never dropped.
- `CHAT_TZ` (default `Asia/Tokyo`): the day of the limits and of the
  records' files is this time zone's date, and the devices show the times
  of the messages in it. It becomes the container's `TZ` (a `TZ` line in
  `.env` is not used).

## 5. Pull and start

The image is published for each version on the GitHub Container Registry
(`ghcr.io/ruby-asterism/asterism-chat:<version>`, also `:<major>.<minor>`
and `:latest`; amd64), built by the repository's CI from the tag
`v<version>`.

```
./update.sh 0.2.0         # checks out v0.2.0, pulls its image and starts it
```

By hand, the same is `git checkout v0.2.0`, `CHAT_VERSION=0.2.0` in
`.env`, then `docker compose pull && docker compose up -d`.

### Building the image yourself

```
docker compose -f docker-compose.yml -f docker-compose.build.yml build
docker compose up -d
```

Give it a name of your own in `.env` first (`CHAT_IMAGE=asterism-chat-local`),
so a later pull does not replace it. `./update.sh --build 0.2.0` does the
same from the version's tag.

## 6. Check

```
docker compose ps                                   # chat: running (healthy)
docker compose exec chat bundle exec exe/asterism-chat status
      # asterism-chat 0.2.0 chat/chat/room: up, joined to tls/zenohd:7448 (since ..., rooms: family 0, games 0, today 0 posts, stamps 0)
docker compose logs --tail 4 chat
      # asterism-chat 0.2.0: chat/chat/room on tls/zenohd:7448
      # asterism-chat: rooms family games friends, 500 messages kept a room, 300 posts a device a day
      # asterism-chat: stamps 0 kept (0 bytes), up to 2000 and 16777216 bytes, 30 new a device a day
```

Then, on a device with the role: open Chat. It lists the rooms; a message
sent there shows on the other devices. A device without the role does
not find the host; a device with the role that is not in
`ASTERISM_CHAT_DEVICES` is told it is not registered.

`status` exits 0 when the chat host is joined to the router with the room
exposed, 1 when not (the router is away: "the router is away, joining it
again"; or it is stopping), 2 when it has written no status for 15
seconds. The healthcheck runs it every 30 s: three failures in a row make
the container unhealthy. It joins the router again by itself when the
router comes back.

## 7. Updating and going back

```
./update.sh 0.2.0                 # the new version
./update.sh --sudo 0.2.0          # when docker needs sudo
./update.sh 0.1.0                 # back to the version before (its image is kept)
```

A restart (an update, `docker compose restart`, the server's reboot) does
not lose the history, the display names, the pictures, the records or the
day's counts (the volume). It takes a few seconds. A post sent while the
host stops is refused (the device shows "チャットホストが止まるところです。
少し待ってからもう一度送ってください。"); one sent while it is away gets no
answer, and the device keeps it and sends it again once the host is back.
There is no `--when-idle`: the chat host has no work in progress to wait
for.

A new certificate for the row `chat`: put the new `.tar` in place and
`docker compose restart chat`.

## 8. Reading the records

One JSON object per line, one file a day (`chat-YYYY-MM-DD.jsonl`), in the
volume's `log/`:

```
docker compose exec chat ls /state/log
docker compose exec chat tail -n 20 /state/log/chat-2026-11-21.jsonl    # the date is CHAT_TZ's
docker compose exec chat sh -c 'grep -c "\"ev\":\"post\"" /state/log/*.jsonl'    # posts per day
```

`ev` is `start`, `hello`, `name` (a display name set), `post` (the room,
the number and the length, or the stamp's sha), `stamp` (a new picture:
its sha, size, width, height and device), `refused` (a device not
registered, a limit, a picture refused and why, the stop) and `stop`. The
text of a message and the pictures are never in them: the text lives in
the history only (and goes when the room has more than
`ASTERISM_CHAT_HISTORY` messages), the pictures in `store/stamps/`. The
gem never deletes the records; the console's backup does not take them.

## 9. Browsers

The browser build (Family mruby in a web page, opened from the console)
can use the chat too, for the users you name. It needs **console 0.4.2
or later**: the role is given per user there, and the router gives it only
to the page the console's door connects with that user's certificate
(`wasm-<handle>`).

1. **In the console** (Admin > Members > Browsers): the user has a handle
   and a certificate ("in the ACL"; "Make the missing certificates" and
   Apply otherwise). Edit the user, tick `chat` under "Roles of this
   browser", Save, Apply.
2. **In `.env`**: add the user's browser node to the devices,
   `ASTERISM_CHAT_DEVICES=fmruby-aaaaaa,wasm-<handle>`, then
   `docker compose up -d`.
3. The user opens the browser build from the console ("Launch Web
   Studio" or a pass's link) and starts Chat.

Leave "Browsers have this role" off on the role `chat`: with it, every
browser page would get the role, the pages that come through the shared
connection too, and those can call under any browser's name (and so post
under it). Only the user's own page reaches the rooms. Another user's
browser, and any page without the user's certificate, does not find the
host.

## 10. Memory

Measured on a local router (plain TCP, two stand-in devices, a few
messages and a stamp): about 50 MB RSS for the gem, 28 MB as docker
counts it; the healthcheck's command about 21 MB while it runs (a second
or so every 30 s). The container's limit is `CHAT_MEM_LIMIT` (192 MB);
over it, the kernel stops the process and docker starts it again (nothing
is lost: everything is on the volume). Not measured: a long run with many
rooms and a full set of pictures (the history of every room is held in
memory, 500 messages of at most about 700 bytes each a room).

## 11. Backing up

The volume `asterism-chat_state` holds the history, the names and the
pictures; the console's daily backup does not take it. To keep a copy:

```
docker compose cp chat:/state ./chat-state-$(date +%F)
```

## 12. Removing

```
docker compose down                 # the container; the volume asterism-chat_state (history, pictures, records) stays
```

In the console: disable or remove the row `chat` and untick `chat` on the
devices' rows, then Apply.
