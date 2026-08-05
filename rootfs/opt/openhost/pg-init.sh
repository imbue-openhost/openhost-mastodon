#!/command/with-contenv bash
# pg-init: oneshot that runs before the postgres longrun service starts.
#
# Idempotent: on the very first boot we run `initdb` against the empty
# $PGDATA dir; on subsequent boots PG_VERSION already exists and we no-op.
#
# We DO NOT do any Mastodon DB setup here — that's the bootstrap
# oneshot's job, and it runs after postgres is up. Here we only put the
# data directory into a state where postgres can start.
set -eu

log() { echo "[pg-init] $*" >&2; }

PGDATA="${PGDATA:-/data/app_data/mastodon/postgres}"

# OpenHost guarantees $OPENHOST_APP_DATA_DIR exists. We mkdir the
# postgres subdir under it explicitly because OpenHost only creates the
# parent.
mkdir -p "$PGDATA"
chown postgres:postgres "$PGDATA"
# Postgres refuses to start unless PGDATA is mode 0700 (or 0750 on
# newer versions). Setting it explicitly is a no-op when it's already
# right but rescues the case where a previous build wrote it 0755.
chmod 0700 "$PGDATA"

if [[ -f "$PGDATA/PG_VERSION" ]]; then
    log "data dir already initialised (PG_VERSION=$(cat "$PGDATA"/PG_VERSION)); skipping initdb"
    exit 0
fi

log "initialising new postgres cluster at $PGDATA"

# Use `trust` auth on the local socket. This is safe inside the
# container because (a) postgres only listens on the unix socket plus
# 127.0.0.1 (see the longrun's run script) and (b) only the mastodon
# user inside the container connects. We still set a password on the
# mastodon role for belt-and-suspenders — if Mastodon's DATABASE_URL
# decides to use TCP somewhere down the line, the password is the
# fallback.
s6-setuidgid postgres /usr/lib/postgresql/15/bin/initdb \
    -D "$PGDATA" \
    --username=postgres \
    --auth-local=trust \
    --auth-host=md5 \
    --encoding=UTF8 \
    --locale=C.UTF-8

# Mastodon performs a lot of small inserts (federation, timelines).
# Tighten a few defaults so the first-time experience isn't bottlenecked
# by postgres's tiny shipped shared_buffers. These are conservative for
# a 3 GB-RAM container.
cat >> "$PGDATA/postgresql.conf" <<'EOF'

# --- openhost-mastodon tuning (added by pg-init) ---
shared_buffers = 256MB
work_mem = 16MB
maintenance_work_mem = 64MB
effective_cache_size = 1GB
# Quieter default logging; flip to DEBUG1 when debugging migrations.
log_min_messages = warning
log_min_error_statement = error
# Sidekiq pile-ups can briefly spike connection count past the
# 100-default. Mastodon's web (puma 5x16) + sidekiq (5) + streaming
# (small pool) easily reaches 60 concurrent at the high end.
max_connections = 100
EOF

log "pg-init complete; postgres ready to start"
