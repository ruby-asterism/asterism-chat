# deploy/vps: the chat host on a server

asterism-chat next to an Asterism console (its `deploy/vps`), serving the
rooms to the devices that have the console's role `chat` through the
console's router. **The steps are in [docs/install.md](../../docs/install.md).**

| File | |
|---|---|
| `docker-compose.yml` | the chat host (project `asterism-chat`) on the published image `ghcr.io/ruby-asterism/asterism-chat:<version>`: the console's `router` network by name, its own `state` volume (the history, the names, the pictures, the records), `credentials/` read-only, a healthcheck (`asterism-chat status`) |
| `docker-compose.build.yml` | to build the image here instead of pulling it |
| `Dockerfile` | the image (the CI builds it for each tag `v<version>`) |
| `env.example` | the settings (the rooms, the devices, the limits), copied to `.env` (never committed) |
| `credentials/` | the chat host's own `.tar` from the console (never committed) |
| `update.sh` | pull a version's image and restart in one command (`--build` builds it here). No `--when-idle`: the chat host has no work in progress; a restart takes a few seconds |

The chat host's volume is not in the console's daily backup (the history and
the pictures stay in this volume only; docs/install.md, "Backing up").
