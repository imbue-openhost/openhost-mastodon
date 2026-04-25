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

# Stamp into the s6 container_environment so the longruns see it.
CENV=/run/s6/container_environment
mkdir -p "$CENV"
printf '%s' "$LOCAL_DOMAIN_VAL" > "$CENV/LOCAL_DOMAIN"
printf '%s' "$LOCAL_DOMAIN_VAL" > "$CENV/WEB_DOMAIN"

# Mastodon's database connection: local unix socket via the postgres
# user with no password (trust auth on local sockets, set by pg-init).
# We write DATABASE_URL pointing at the same socket so streaming (which
# only honours DATABASE_URL, not the DB_* split) connects the same way.
DATABASE_URL_VAL="postgresql:///mastodon?host=/var/run/postgresql&user=mastodon"
printf '%s' "$DATABASE_URL_VAL"     > "$CENV/DATABASE_URL"
printf '%s' "redis://127.0.0.1:6379" > "$CENV/REDIS_URL"
printf '%s' "mastodon"              > "$CENV/DB_USER"
printf '%s' "mastodon"              > "$CENV/DB_NAME"
printf '%s' "/var/run/postgresql"   > "$CENV/DB_HOST"
printf '%s' "5432"                  > "$CENV/DB_PORT"

# SMTP: configure delivery to /dev/null. Mastodon's mailer must have a
# valid configuration block to boot but we don't actually want to send
# email from a test instance. `test` delivery method swallows mail and
# stashes it in ActionMailer::Base.deliveries (in-process; nobody sees it).
# This means new-user signups silently fail — there's no confirmation
# email — so we use tootctl below to create the admin without one.
printf '%s' "test"                                  > "$CENV/SMTP_DELIVERY_METHOD"
printf '%s' "Mastodon <notifications@$LOCAL_DOMAIN_VAL>" > "$CENV/SMTP_FROM_ADDRESS"
printf '%s' "en"                                    > "$CENV/DEFAULT_LOCALE"

# Tell Rails to trust the proxy chain. Caddy + the OpenHost router are
# both forwarders we control.
printf '%s' "true" > "$CENV/TRUST_ALL_PROXIES"

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
# We add SKIP_POST_DEPLOYMENT_MIGRATIONS=true on the first migrate
# pass to follow upstream's recommended two-phase upgrade procedure
# (see docs/admin/upgrading), then a second pass without it to apply
# the post-deployment ones. On a brand-new database both passes run
# every migration; on a migration-up-to-date database both are no-ops.
log "running db:migrate (this is slow on first boot — be patient)"
cd /opt/mastodon
s6-setuidgid mastodon env \
    LOCAL_DOMAIN="$LOCAL_DOMAIN" WEB_DOMAIN="$WEB_DOMAIN" \
    DATABASE_URL="$DATABASE_URL" REDIS_URL="$REDIS_URL" \
    DB_HOST="$DB_HOST" DB_USER="$DB_USER" DB_NAME="$DB_NAME" DB_PORT="$DB_PORT" \
    SECRET_KEY_BASE="$SECRET_KEY_BASE" OTP_SECRET="$OTP_SECRET" \
    VAPID_PRIVATE_KEY="$VAPID_PRIVATE_KEY" VAPID_PUBLIC_KEY="$VAPID_PUBLIC_KEY" \
    ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY="$ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY" \
    ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY="$ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY" \
    ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT="$ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT" \
    RAILS_ENV=production SKIP_POST_DEPLOYMENT_MIGRATIONS=true \
    /usr/local/bin/bundle exec rails db:migrate

s6-setuidgid mastodon env \
    LOCAL_DOMAIN="$LOCAL_DOMAIN" WEB_DOMAIN="$WEB_DOMAIN" \
    DATABASE_URL="$DATABASE_URL" REDIS_URL="$REDIS_URL" \
    DB_HOST="$DB_HOST" DB_USER="$DB_USER" DB_NAME="$DB_NAME" DB_PORT="$DB_PORT" \
    SECRET_KEY_BASE="$SECRET_KEY_BASE" OTP_SECRET="$OTP_SECRET" \
    VAPID_PRIVATE_KEY="$VAPID_PRIVATE_KEY" VAPID_PUBLIC_KEY="$VAPID_PUBLIC_KEY" \
    ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY="$ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY" \
    ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY="$ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY" \
    ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT="$ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT" \
    RAILS_ENV=production \
    /usr/local/bin/bundle exec rails db:migrate

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
    TOOTCTL_OUTPUT=$(s6-setuidgid mastodon env \
        LOCAL_DOMAIN="$LOCAL_DOMAIN" WEB_DOMAIN="$WEB_DOMAIN" \
        DATABASE_URL="$DATABASE_URL" REDIS_URL="$REDIS_URL" \
        DB_HOST="$DB_HOST" DB_USER="$DB_USER" DB_NAME="$DB_NAME" DB_PORT="$DB_PORT" \
        SECRET_KEY_BASE="$SECRET_KEY_BASE" OTP_SECRET="$OTP_SECRET" \
        VAPID_PRIVATE_KEY="$VAPID_PRIVATE_KEY" VAPID_PUBLIC_KEY="$VAPID_PUBLIC_KEY" \
        ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY="$ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY" \
        ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY="$ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY" \
        ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT="$ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT" \
        RAILS_ENV=production \
        /opt/mastodon/bin/tootctl accounts create "$ADMIN_USER" \
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
