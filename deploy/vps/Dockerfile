# The chat host's image (asterism-chat): CRuby, the gems of Gemfile.lock
# and the gem itself. Published for each version by
# .github/workflows/image.yml as ghcr.io/ruby-asterism/asterism-chat
# (docs/install.md); built here instead with docker-compose.build.yml, or
# by hand from the repository's root:
#   docker build -f deploy/vps/Dockerfile -t asterism-chat:dev .
#
# asterism-zenoh compiles its C extension against the zenoh-c release it
# pins, downloaded while the image is built; prism and msgpack compile
# theirs. The runtime stage has no compiler.
#
# No key is in the image: the router's certificate is mounted read-only at
# /credentials.
ARG RUBY_VERSION=3.4.13
FROM ruby:${RUBY_VERSION}-slim AS build

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential curl git pkg-config unzip ca-certificates && \
    rm -rf /var/lib/apt/lists/*

ENV BUNDLE_WITHOUT=development:test \
    BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_DEPLOYMENT=1

WORKDIR /app
COPY Gemfile Gemfile.lock asterism-chat.gemspec ./
COPY lib/chat/version.rb lib/chat/version.rb
RUN bundle install && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git

COPY . .

FROM ruby:${RUBY_VERSION}-slim

ARG CHAT_VERSION=dev
LABEL org.opencontainers.image.title="asterism-chat" \
      org.opencontainers.image.source="https://github.com/ruby-asterism/asterism-chat" \
      org.opencontainers.image.description="A chat host for Family mruby devices over Asterism: rooms, history and stamps" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${CHAT_VERSION}"

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# The records, the history, the names and the stamps go to the state
# volume (docker-compose.yml); the router's certificate is the console's
# .tar in /credentials.
ENV BUNDLE_WITHOUT=development:test \
    BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_DEPLOYMENT=1 \
    ASTERISM_CHAT_LOG_DIR=/state/log \
    ASTERISM_CHAT_STATE_DIR=/state/store

WORKDIR /app
COPY --from=build /usr/local/bundle /usr/local/bundle
COPY --from=build /app /app

# Runs as 1000, the owner of credentials/ on the server (docs/install.md).
RUN groupadd --system --gid 1000 chat && useradd --uid 1000 --gid 1000 --no-create-home chat && \
    mkdir -p /state && chown chat:chat /state
USER 1000:1000

CMD ["bundle", "exec", "exe/asterism-chat"]
