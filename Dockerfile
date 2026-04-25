# syntax=docker/dockerfile:1.7
#
# Mastodon — all-in-one container for OpenHost.
#
# Mastodon's standard production deploy is five processes spread across as
# many containers (postgres, redis, mastodon-web puma, mastodon-streaming
# node, mastodon-sidekiq workers). OpenHost is "one container per app",
# so we bundle them all into one image and supervise them with s6-overlay
# v3. The same trick the openhost-jitsi wrapper uses for the four-service
# Jitsi stack.
#
# Base image strategy
# -------------------
#  * Ruby half (web, sidekiq, rails CLI) — taken straight from the
#    upstream `ghcr.io/mastodon/mastodon` image. That image is itself a
#    `ruby:slim-trixie` build with libvips, ffmpeg, the bundled gems, and
#    the precompiled assets already baked in. We use it as the base for
#    the final image so we inherit all of that without rebuilding.
#
#  * Node half (streaming) — copied out of
#    `ghcr.io/mastodon/mastodon-streaming` into /opt/mastodon-streaming
#    (sources + production node_modules already installed). We also copy
#    the node binary itself out of that image since the Ruby base image
#    doesn't ship one.
#
#  * Postgres + Redis + Caddy + s6-overlay — installed from Debian trixie
#    apt repos at build time.
#
# Versions are pinned in MASTODON_VERSION below. Bump together. Mastodon
# federation is HISTORY-SENSITIVE: the canonical hostname for an instance
# is embedded forever once it federates with anyone, so this image's
# upgrade path is the standard "pull new image, run db:migrate, restart"
# flow — not a wholesale data migration.

ARG MASTODON_VERSION=v4.5.9

# -- web/sidekiq source image --------------------------------------------
FROM ghcr.io/mastodon/mastodon:${MASTODON_VERSION} AS mastodon-src

# -- streaming source image (node + production node_modules) -------------
FROM ghcr.io/mastodon/mastodon-streaming:${MASTODON_VERSION} AS streaming-src

# -- final image ---------------------------------------------------------
FROM ghcr.io/mastodon/mastodon:${MASTODON_VERSION}

ARG DEBIAN_FRONTEND=noninteractive
# s6-overlay v3 is shipped as two tarballs (noarch + arch) extracted into /.
# Pin a recent stable release to keep build behaviour reproducible.
ARG S6_OVERLAY_VERSION=3.2.0.2

# We need root for the rest of the build. The upstream image ends with
# `USER mastodon`; flip back to root, do everything, and let s6-overlay's
# init drop privileges per-service via s6-setuidgid in the run scripts.
USER root

# Add Debian's PostgreSQL APT repository so we install postgres-15 to match
# Mastodon's tested matrix. (Mastodon supports 14+; trixie's default
# postgresql package is 17, which works but is newer than upstream's CI.
# Keeping 15 to match what most production Mastodon admins are running.)
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg lsb-release \
 && install -d -m 0755 /usr/share/postgresql-common/pgdg \
 && curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
        -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc \
 && echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt trixie-pgdg main" \
        > /etc/apt/sources.list.d/pgdg.list

# Caddy 2 from cloudsmith (official upstream apt repo). We use Caddy as the
# in-container HTTP front-end — it routes /api/v1/streaming/* to the node
# streaming process and everything else to Puma, and rewrites the Host
# header from X-Forwarded-Host so Mastodon sees the public hostname (the
# OpenHost router strips Host on the way through).
#
# We write the .list file ourselves rather than `curl ... | tee
# /etc/apt/sources.list.d/caddy.list` (which is what cloudsmith's
# debian.deb.txt-style installer does) because we want a single
# Debian dist that doesn't change shape between Debian releases —
# cloudsmith's bundled file uses the architecture's `lsb_release -cs`
# value, which on trixie evaluates to literal "trixie" but is empty
# inside our build sandbox where lsb-release is not yet installed.
# Hardcoding `any-version` is the dist Caddy publishes for all Debian
# versions and matches what cloudsmith's deb-helper installs anyway.
# The keyring path is the standard one cloudsmith expects.
RUN install -d -m 0755 /usr/share/keyrings \
 && curl -1sSLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
        | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg \
 && echo "deb [signed-by=/usr/share/keyrings/caddy-stable-archive-keyring.gpg] https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version main" \
        > /etc/apt/sources.list.d/caddy-stable.list

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        bash xz-utils \
        postgresql-15 postgresql-client-15 postgresql-contrib-15 \
        redis-server \
        caddy \
        gosu \
 && rm -rf /var/lib/apt/lists/*

# Install s6-overlay v3 (used to supervise postgres, redis, caddy, and
# the three Mastodon services in one container). v3 supports per-service
# dependency tracking which we use so mastodon-* won't start before
# postgres + redis report ready.
RUN curl -fsSL "https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-noarch.tar.xz" \
        | tar -C / -Jxpf - \
 && curl -fsSL "https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-x86_64.tar.xz" \
        | tar -C / -Jxpf -

# Pull node + the streaming app + its production node_modules from the
# upstream streaming image. The streaming image is also built on
# debian-trixie-slim so binaries are ABI-compatible. We deliberately drop
# /opt/mastodon-streaming alongside (not into) /opt/mastodon — the two
# share their own .yarn cache files in the streaming image and we don't
# want the Ruby tree's .yarn (which is configured for the workspace
# *monorepo*) overwriting them.
COPY --from=streaming-src /usr/local/bin/node /usr/local/bin/node
COPY --from=streaming-src /usr/local/bin/corepack /usr/local/bin/corepack
COPY --from=streaming-src /usr/local/lib/node_modules /usr/local/lib/node_modules
COPY --from=streaming-src /opt/mastodon /opt/mastodon-streaming

# The streaming image leaves /opt/mastodon-streaming owned by mastodon
# (uid 991) — same uid the final image already created. We rely on that.

# ----- s6 service tree ---------------------------------------------------
# /etc/s6-overlay/s6-rc.d/<svc>/{type,run,dependencies.d/<dep>}
# Custom scripts go to /opt/openhost/{bootstrap.sh,*}.
RUN mkdir -p /opt/openhost
COPY rootfs/ /
RUN chmod +x /opt/openhost/*.sh /etc/s6-overlay/s6-rc.d/*/run \
             /etc/s6-overlay/scripts/*.sh 2>/dev/null || true

# Wire up the user bundle so s6-rc actually starts our services. The
# bundle name "user" is the conventional one s6-overlay v3 boots into
# unless overridden via S6_STAGE2_HOOK.
RUN mkdir -p /etc/s6-overlay/s6-rc.d/user/contents.d \
 && for svc in pg-init secrets-init bootstrap postgres redis caddy \
               mastodon-web mastodon-streaming mastodon-sidekiq; do \
        touch /etc/s6-overlay/s6-rc.d/user/contents.d/$svc; \
    done

# Pre-create state dirs (also created at runtime by bootstrap.sh, but
# nice to have ready).
RUN mkdir -p /run/postgresql /run/redis \
 && chown postgres:postgres /run/postgresql \
 && chown redis:redis /run/redis

# Mastodon expects /opt/mastodon/public/system (uploads) writable by uid
# mastodon. We bind-mount $OPENHOST_APP_DATA_DIR/mastodon-uploads on top
# of it at runtime via bootstrap.sh, so this is just the fallback default.
RUN mkdir -p /opt/mastodon/public/system /opt/mastodon/tmp \
 && chown -R mastodon:mastodon /opt/mastodon/public/system /opt/mastodon/tmp

# s6-overlay tunables. We let services exit cleanly (S6_KILL_GRACETIME,
# default 5000ms = 5s, is too short for Postgres to flush WAL on a
# busy instance) and propagate any service exit through to PID 1 so
# OpenHost notices and restarts.
ENV S6_KEEP_ENV=1 \
    S6_BEHAVIOUR_IF_STAGE2_FAILS=2 \
    S6_KILL_GRACETIME=30000 \
    S6_SERVICES_GRACETIME=30000 \
    PGDATA=/data/app_data/mastodon/postgres \
    POSTGRES_USER=mastodon \
    POSTGRES_DB=mastodon \
    REDIS_URL=redis://localhost:6379 \
    DEFAULT_LOCALE=en \
    SMTP_DELIVERY_METHOD=test \
    NODE_ENV=production \
    RAILS_ENV=production \
    DB_HOST=/var/run/postgresql \
    DB_USER=mastodon \
    DB_NAME=mastodon \
    DB_PORT=5432 \
    LOCAL_DOMAIN_AUTODETECT=1 \
    PATH=/usr/local/bin:/usr/bin:/bin:/opt/mastodon/bin

EXPOSE 8080

ENTRYPOINT ["/init"]
