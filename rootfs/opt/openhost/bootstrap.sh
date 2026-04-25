#!/command/with-contenv bash
# bootstrap: oneshot that runs after postgres + redis are up and after
# secrets-init has stamped persistent secrets into container_environment.
#
# Responsibilities (idempotent — safe to run on every boot):
#   1. Derive LOCAL_DOMAIN / WEB_DOMAIN from OpenHost env vars and
#      stamp them into container_environment so puma + sidekiq +
#      streaming all see the same value. **Federation identity is
#      permanent** — once Mastodon has handshaken with any remote
#      server using this domain, it cannot be changed without breaking
#      every existing federation handshake. We commit to the OpenHost
#      app subdomain on first boot and never look back.
#   2. Bind-mount $OPENHOST_APP_DATA_DIR/mastodon-uploads onto
#      /opt/mastodon/public/system so paperclip writes (avatars,
#      attachments, custom emoji) survive container redeploys.
#   3. Create the mastodon postgres role + database if they don't
#      exist yet. We use the local socket as the postgres superuser
#      (trust auth set by pg-init).
#   4. Run db:migrate (no-op when up to date).
#   5. On the very first boot, create an admin user via
#      `tootctl accounts create operator --confirmed --role Owner` and
#      capture the rake-printed temporary password to
#      $OPENHOST_APP_DATA_DIR/admin-password.txt.
#
# When this script exits 0, the three Mastodon longruns (web, sidekiq,
# streaming) start in parallel.
set -euo pipefail

log() { echo "[bootstrap] $*" >&2; }

PERSIST="${OPENHOST_APP_DATA_DIR:-/data/app_data/mastodon}"
TEMP="${OPENHOST_APP_TEMP_DIR:-/data/app_temp_data/mastodon}"
mkdir -p "$PERSIST" "$TEMP"

# ----- 1. derive federation identity ------------------------------------
#
# Priority: explicit LOCAL_DOMAIN env > cached value from previous boot >
# {OPENHOST_APP_NAME}.{OPENHOST_ZONE_DOMAIN}. The cache file wins over a
# fresh env-var derivation because the env vars *could* legitimately
# change between deploys (operator renames the app) but we MUST NOT
# silently switch the federation identity if that happens — it would
# brick the instance. The safe thing is: pin the first value we ever
# see and require manual intervention to change it.
DOMAIN_CACHE_FILE="$PERSIST/local-domain"

if [[ -f "$DOMAIN_CACHE_FILE" ]]; then
    LOCAL_DOMAIN_VAL="$(cat "$DOMAIN_CACHE_FILE")"
    log "using cached LOCAL_DOMAIN=$LOCAL_DOMAIN_VAL (do not change without wiping data)"
elif [[ -n "${LOCAL_DOMAIN:-}" ]]; then
    LOCAL_DOMAIN_VAL="$LOCAL_DOMAIN"
    log "using operator-provided LOCAL_DOMAIN=$LOCAL_DOMAIN_VAL"
elif [[ -n "${OPENHOST_APP_NAME:-}" && -n "${OPENHOST_ZONE_DOMAIN:-}" ]]; then
    LOCAL_DOMAIN_VAL="${OPENHOST_APP_NAME}.${OPENHOST_ZONE_DOMAIN}"
    log "derived LOCAL_DOMAIN=$LOCAL_DOMAIN_VAL from OPENHOST_APP_NAME + OPENHOST_ZONE_DOMAIN"
else
    log "FATAL: cannot derive LOCAL_DOMAIN — neither cache nor OPENHOST_APP_NAME+OPENHOST_ZONE_DOMAIN nor LOCAL_DOMAIN is set"
    exit 1
fi

# Refuse to change the cached value silently. If OPENHOST_APP_NAME or
# OPENHOST_ZONE_DOMAIN changed mid-life, the operator must intentionally
# wipe data and start over.
if [[ -f "$DOMAIN_CACHE_FILE" && -n "${OPENHOST_APP_NAME:-}" && -n "${OPENHOST_ZONE_DOMAIN:-}" ]]; then
    EXPECTED_FROM_ENV="${OPENHOST_APP_NAME}.${OPENHOST_ZONE_DOMAIN}"
    if [[ "$LOCAL_DOMAIN_VAL" != "$EXPECTED_FROM_ENV" ]]; then
        log "WARNING: cached domain ($LOCAL_DOMAIN_VAL) differs from env-derived ($EXPECTED_FROM_ENV)."
        log "WARNING: keeping the cached value. To change federation identity, wipe \$OPENHOST_APP_DATA_DIR and redeploy."
    fi
fi

echo "$LOCAL_DOMAIN_VAL" > "$DOMAIN_CACHE_FILE"

# Append derived runtime config to the secrets file. The three Mastodon
# longruns (web, sidekiq, streaming) all source the secrets file at
# exec time, which means we don't have to fight with s6-overlay's
# `with-contenv` env-propagation timing — whatever's in this file is
# what the services will see.
#
# We rewrite (rather than append) the runtime block on every boot so
# changes to LOCAL_DOMAIN policy in this script reach the longruns
# immediately. We use a marker line to find the start of "our" block
# and truncate from there. The static crypto secrets above the marker
# are preserved; everything below is rewritten.
SECRETS_FILE="$PERSIST/mastodon-secrets.env"
RUNTIME_MARKER="# --- runtime config (regenerated every boot) ---"
if grep -qF "$RUNTIME_MARKER" "$SECRETS_FILE"; then
    # Truncate from the marker line onward.
    sed -i "/^${RUNTIME_MARKER}\$/,\$d" "$SECRETS_FILE"
fi

DATABASE_URL_VAL="postgresql:///mastodon?host=/var/run/postgresql&user=mastodon"

cat >> "$SECRETS_FILE" <<EOF
$RUNTIME_MARKER
LOCAL_DOMAIN=$LOCAL_DOMAIN_VAL
WEB_DOMAIN=$LOCAL_DOMAIN_VAL
DATABASE_URL=$DATABASE_URL_VAL
REDIS_URL=redis://127.0.0.1:6379
DB_HOST=/var/run/postgresql
DB_USER=mastodon
DB_NAME=mastodon
DB_PORT=5432
SMTP_DELIVERY_METHOD=test
SMTP_FROM_ADDRESS=Mastodon <notifications@$LOCAL_DOMAIN_VAL>
DEFAULT_LOCALE=en
RAILS_ENV=production
NODE_ENV=production
TRUST_ALL_PROXIES=true
EOF

# Re-source so the rest of THIS script sees these too.
export LOCAL_DOMAIN="$LOCAL_DOMAIN_VAL"
export WEB_DOMAIN="$LOCAL_DOMAIN_VAL"
export DATABASE_URL="$DATABASE_URL_VAL"
export REDIS_URL="redis://127.0.0.1:6379"
export DB_HOST="/var/run/postgresql"
export DB_USER="mastodon"
export DB_NAME="mastodon"
export DB_PORT="5432"
export SMTP_DELIVERY_METHOD="test"
export SMTP_FROM_ADDRESS="Mastodon <notifications@$LOCAL_DOMAIN_VAL>"
export DEFAULT_LOCALE="en"
export RAILS_ENV="production"
export NODE_ENV="production"
export TRUST_ALL_PROXIES="true"

# Source the secrets file so SECRET_KEY_BASE & friends are in our env
# for the rake commands below.
SECRETS_FILE="$PERSIST/mastodon-secrets.env"
if [[ ! -f "$SECRETS_FILE" ]]; then
    log "FATAL: secrets file missing at $SECRETS_FILE (secrets-init must run before bootstrap)"
    exit 1
fi
# shellcheck disable=SC1090
set -a; source "$SECRETS_FILE"; set +a

# ----- 2. uploads bind-mount --------------------------------------------
#
# Paperclip writes user uploads under /opt/mastodon/public/system.
# We want those on the persisted volume. We can't bind-mount inside a
# running container without privileged mode, so instead we replace the
# directory with a symlink to the persisted location. The mastodon
# user (uid 991) inside the container needs to own the persisted dir
# — set that here.
UPLOADS_DIR="$PERSIST/mastodon-uploads"
mkdir -p "$UPLOADS_DIR"
chown -R mastodon:mastodon "$UPLOADS_DIR"

# Replace /opt/mastodon/public/system with a symlink to $UPLOADS_DIR
# unless the symlink already points at the right place. A naive
# `ln -sf` would happily create a symlink-inside-the-existing-dir
# (`/opt/mastodon/public/system/mastodon-uploads`) so do the swap
# explicitly.
if [[ -L /opt/mastodon/public/system ]]; then
    CURRENT_TARGET=$(readlink /opt/mastodon/public/system)
    if [[ "$CURRENT_TARGET" != "$UPLOADS_DIR" ]]; then
        log "fixing uploads symlink: $CURRENT_TARGET -> $UPLOADS_DIR"
        rm /opt/mastodon/public/system
        ln -s "$UPLOADS_DIR" /opt/mastodon/public/system
    fi
elif [[ -d /opt/mastodon/public/system ]]; then
    # First-boot case: replace the empty default dir with a symlink.
    # If somehow there's data already in there (unlikely on a fresh
    # image, but be defensive) move it into the persisted location.
    if [[ -n "$(ls -A /opt/mastodon/public/system 2>/dev/null)" ]]; then
        log "migrating existing /opt/mastodon/public/system contents into $UPLOADS_DIR"
        cp -a /opt/mastodon/public/system/. "$UPLOADS_DIR/"
    fi
    rm -rf /opt/mastodon/public/system
    ln -s "$UPLOADS_DIR" /opt/mastodon/public/system
else
    ln -s "$UPLOADS_DIR" /opt/mastodon/public/system
fi

# ----- 3. wait for postgres to be ready ---------------------------------
#
# s6-rc declared us as depending on the `postgres` longrun, which means
# s6 has started postgres before us — but "started" means the process
# is supervised, not that it's accepting connections. Loop on
# pg_isready until either it answers or 60s pass.
log "waiting for postgres to accept connections..."
for i in $(seq 1 60); do
    if s6-setuidgid postgres /usr/lib/postgresql/15/bin/pg_isready \
            -h /var/run/postgresql -U postgres -d postgres -q; then
        log "postgres ready"
        break
    fi
    if [[ $i -eq 60 ]]; then
        log "FATAL: postgres did not become ready within 60s"
        exit 1
    fi
    sleep 1
done

# ----- 4. ensure mastodon role + database -------------------------------
#
# Both are idempotent. CREATE ROLE / CREATE DATABASE will error if
# they already exist, so we check first.
if ! s6-setuidgid postgres /usr/lib/postgresql/15/bin/psql \
        -h /var/run/postgresql -U postgres -d postgres -tAc \
        "SELECT 1 FROM pg_roles WHERE rolname='mastodon'" | grep -q 1; then
    log "creating postgres role 'mastodon'"
    s6-setuidgid postgres /usr/lib/postgresql/15/bin/psql \
        -h /var/run/postgresql -U postgres -d postgres -v ON_ERROR_STOP=1 \
        -c "CREATE ROLE mastodon WITH LOGIN CREATEDB PASSWORD '$POSTGRES_PASSWORD';"
fi

if ! s6-setuidgid postgres /usr/lib/postgresql/15/bin/psql \
        -h /var/run/postgresql -U postgres -d postgres -tAc \
        "SELECT 1 FROM pg_database WHERE datname='mastodon'" | grep -q 1; then
    log "creating database 'mastodon' owned by 'mastodon'"
    s6-setuidgid postgres /usr/lib/postgresql/15/bin/psql \
        -h /var/run/postgresql -U postgres -d postgres -v ON_ERROR_STOP=1 \
        -c "CREATE DATABASE mastodon OWNER mastodon;"
fi

# ----- 5. db:migrate ----------------------------------------------------
#
# `bundle exec rails db:migrate` is idempotent — it walks the
# schema_migrations table and applies anything new. On first boot it
# walks every migration and creates all the tables.
#
# DO NOT set SKIP_POST_DEPLOYMENT_MIGRATIONS=true here. That env var is
# meant for the rolling-upgrade procedure documented at
# docs.joinmastodon.org/admin/upgrading/ — it's only sensible when the
# database is at a version >= 4.2 and you want to migrate without
# downtime. On a brand-new database the upstream rake task
# `db:pre_migration_check` rejects it outright because it can't
# distinguish "fresh database" from "obsolete pre-4.2 database" when
# the schema_migrations table doesn't have any of the marker rows it
# expects. We just run a plain db:migrate which works for both fresh
# installs (creates the schema from migration zero) and ongoing
# upgrades (applies whatever's new since the last boot).
log "running db:migrate (this is slow on first boot — be patient)"
cd /opt/mastodon

# We pass every Mastodon-required env var explicitly to env(1) so the
# subshell sees them whether or not s6's container_environment has
# propagated yet. (set -a + source above already exported them, but
# `s6-setuidgid` reset HOME — Ruby's bundler then complains that /root
# isn't writable. The HOME=/tmp override fixes that.)
mastodon_run_rake() {
    s6-setuidgid mastodon env \
        HOME=/tmp \
        LOCAL_DOMAIN="$LOCAL_DOMAIN" WEB_DOMAIN="$WEB_DOMAIN" \
        DATABASE_URL="$DATABASE_URL" REDIS_URL="$REDIS_URL" \
        DB_HOST="$DB_HOST" DB_USER="$DB_USER" \
        DB_NAME="$DB_NAME" DB_PORT="$DB_PORT" \
        SECRET_KEY_BASE="$SECRET_KEY_BASE" OTP_SECRET="$OTP_SECRET" \
        VAPID_PRIVATE_KEY="$VAPID_PRIVATE_KEY" \
        VAPID_PUBLIC_KEY="$VAPID_PUBLIC_KEY" \
        ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY="$ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY" \
        ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY="$ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY" \
        ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT="$ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT" \
        RAILS_ENV=production \
        "$@"
}

mastodon_run_rake /usr/local/bin/bundle exec rails db:migrate

# `db:seed` populates the default UserRole rows (Owner, Admin, Moderator)
# and is required for tootctl to create users with --role Owner. It is
# idempotent — Mastodon's seed file uses `find_or_create_by!` for every
# row, so running it on every boot is safe and only takes a second once
# the rows are already there. We could gate this on first-boot but
# rake-task overhead is dominated by Rails boot (~10s) regardless of
# whether the seed actually inserts anything, and we already paid that
# cost for db:migrate. Run it unconditionally.
log "running db:seed (idempotent)"
mastodon_run_rake /usr/local/bin/bundle exec rails db:seed

# ----- 6. bootstrap admin user (first boot only) ------------------------
#
# `tootctl accounts create` prints a generated password to stdout in
# the format:  "OK\nNew password: xxxx" — we capture that and stash it
# under $OPENHOST_APP_DATA_DIR/admin-password.txt for the operator to
# read once. We use a marker file to guard against re-running and
# generating a confusing second password the operator might then try
# to use.
ADMIN_MARKER="$PERSIST/.admin-bootstrapped"
ADMIN_PW_FILE="$PERSIST/admin-password.txt"
ADMIN_USER="${ADMIN_USERNAME:-operator}"
ADMIN_EMAIL="${ADMIN_EMAIL:-${ADMIN_USER}@${LOCAL_DOMAIN}}"

if [[ -f "$ADMIN_MARKER" ]]; then
    log "admin user already bootstrapped; skipping"
else
    log "creating admin user '$ADMIN_USER' (email=$ADMIN_EMAIL)"
    # `--confirmed` skips the email confirmation flow we can't deliver.
    # `--role Owner` grants the highest permission level (Mastodon's
    # built-in role hierarchy: User < Moderator < Admin < Owner).
    set +e
    TOOTCTL_OUTPUT=$(mastodon_run_rake /opt/mastodon/bin/tootctl accounts create "$ADMIN_USER" \
            --email "$ADMIN_EMAIL" \
            --confirmed \
            --role Owner 2>&1)
    TOOTCTL_RC=$?
    set -e

    if [[ $TOOTCTL_RC -ne 0 ]]; then
        log "tootctl accounts create failed (exit $TOOTCTL_RC):"
        echo "$TOOTCTL_OUTPUT" >&2
        # Don't fail bootstrap — maybe the user already exists from a
        # prior boot whose marker file was lost. The operator can
        # always run tootctl manually via the OpenHost terminal.
        log "WARN: continuing without admin bootstrap; create one manually with tootctl if needed"
    else
        # tootctl prints "OK\nNew password: <pw>" on success.
        ADMIN_PASSWORD=$(echo "$TOOTCTL_OUTPUT" | sed -n 's/^New password: //p')
        if [[ -z "$ADMIN_PASSWORD" ]]; then
            log "WARN: tootctl returned 0 but didn't print a password; output was:"
            echo "$TOOTCTL_OUTPUT" >&2
        else
            umask 077
            cat > "$ADMIN_PW_FILE" <<EOF
Mastodon admin user (created on first boot)
==========================================
URL:       https://$LOCAL_DOMAIN
Username:  $ADMIN_USER
Email:     $ADMIN_EMAIL
Password:  $ADMIN_PASSWORD

Read this once and rotate the password from
  Preferences → Account → Change password
after first login.

(File is at \$OPENHOST_APP_DATA_DIR/admin-password.txt)
EOF
            chmod 0600 "$ADMIN_PW_FILE"
            chown mastodon:mastodon "$ADMIN_PW_FILE"
            log "admin user created; credentials at $ADMIN_PW_FILE"
        fi
    fi

    # Mark bootstrap done even if tootctl failed — we've at least tried.
    touch "$ADMIN_MARKER"
fi

log "bootstrap complete"
