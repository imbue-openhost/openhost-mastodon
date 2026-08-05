#!/command/with-contenv bash
# bootstrap: oneshot that runs after postgres + redis are up and after
# secrets-init has generated/loaded persistent secrets.
#
# Responsibilities (idempotent — safe to run on every boot):
#   1. Derive LOCAL_DOMAIN / WEB_DOMAIN from OpenHost env vars and
#      append them (along with DATABASE_URL, REDIS_URL, SMTP_*, and
#      the rest of the Mastodon runtime config) to the
#      $OPENHOST_APP_DATA_DIR/mastodon-secrets.env file. The three
#      Mastodon longruns (web, sidekiq, streaming) source that file
#      at exec time, so this is how we get config to them — we do
#      not write to /run/s6/container_environment because the
#      `with-contenv` reads happen at unpredictable times during
#      stage 2 and any value we'd add wouldn't reliably reach a
#      longrun whose run script doesn't already source the secrets
#      file. **Federation identity is permanent** — once Mastodon
#      has handshaken with any remote server using this domain, it
#      cannot be changed without breaking every existing federation
#      handshake. We commit to the OpenHost app subdomain on first
#      boot and never look back.
#   2. Bind-mount $OPENHOST_APP_DATA_DIR/mastodon-uploads onto
#      /opt/mastodon/public/system so paperclip writes (avatars,
#      attachments, custom emoji) survive container redeploys.
#   3. Create the mastodon postgres role + database if they don't
#      exist yet. We use the local socket as the postgres superuser
#      (trust auth set by pg-init).
#   4. Run db:migrate (no-op when up to date).
#   5. On the very first boot, create an Owner account via
#      `tootctl accounts create operator --confirmed --approve
#      --role Owner`. The generated password is discarded, NOT written
#      to disk — the zone owner logs in through OpenHost SSO
#      (auth_proxy + session_minter).
#   6. Ensure the owner account is confirmed + approved on every boot
#      (heals older approved:false accounts so SSO lands in the app).
#   7. Seed first-boot content once (welcome post, About text, starter
#      follows) so the instance isn't empty out of the box.
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

# All values are double-quoted because at least one (SMTP_FROM_ADDRESS,
# which contains literal `<...>`) would be interpreted as shell I/O
# redirection by `set -a; source $SECRETS_FILE` otherwise. The simple
# rule: every value goes between double quotes, and if a value ever
# legitimately contains a double quote we'd backslash-escape it. None
# of these values do.
cat >> "$SECRETS_FILE" <<EOF
$RUNTIME_MARKER
LOCAL_DOMAIN="$LOCAL_DOMAIN_VAL"
WEB_DOMAIN="$LOCAL_DOMAIN_VAL"
DATABASE_URL="$DATABASE_URL_VAL"
REDIS_URL="redis://127.0.0.1:6379"
DB_HOST="/var/run/postgresql"
DB_USER="mastodon"
DB_NAME="mastodon"
DB_PORT="5432"
SMTP_DELIVERY_METHOD="test"
SMTP_FROM_ADDRESS="Mastodon <notifications@$LOCAL_DOMAIN_VAL>"
DEFAULT_LOCALE="en"
RAILS_ENV="production"
NODE_ENV="production"
TRUST_ALL_PROXIES="true"
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
# propagated yet. (set -a + source above already exported them.)
# Generic helper to run any command as the mastodon user with a clean
# Mastodon environment. Used for `rails db:migrate`, `rails db:seed`,
# and `tootctl accounts create`. The mastodon user has no real $HOME
# under s6-setuidgid (it inherits root's `/root` which it can't write
# to), so we explicitly set HOME=/tmp before exec — Bundler creates
# .bundle/ in HOME and crashes without a writable HOME.
mastodon_run() {
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
        ADMIN_USERNAME="${ADMIN_USER:-}" \
        OPENHOST_OWNER_USERNAME="${OPENHOST_OWNER_USERNAME:-}" \
        SEED_BACKFILL_PER_ACCOUNT="${SEED_BACKFILL_PER_ACCOUNT:-10}" \
        RAILS_ENV=production \
        "$@"
}

mastodon_run /usr/local/bin/bundle exec rails db:migrate

# `db:seed` populates the default UserRole rows (Owner, Admin, Moderator)
# and is required for tootctl to create users with --role Owner. It is
# idempotent — Mastodon's seed file uses `find_or_create_by!` for every
# row, so running it on every boot is safe and only takes a second once
# the rows are already there. We could gate this on first-boot but
# rake-task overhead is dominated by Rails boot (~10s) regardless of
# whether the seed actually inserts anything, and we already paid that
# cost for db:migrate. Run it unconditionally.
log "running db:seed (idempotent)"
mastodon_run /usr/local/bin/bundle exec rails db:seed

# ----- 6. bootstrap admin user (first boot only) ------------------------
#
# We create a single Owner-role account (`operator`) on first boot. The
# operator NEVER needs a password: OpenHost owner SSO (auth_proxy.py +
# session_minter.rb) logs the zone owner straight into this account.
#
# CREDENTIAL-LEAK POLICY (this is the important change from earlier
# builds): we do NOT persist the account password to disk. OpenHost
# bind-mounts $OPENHOST_APP_DATA_DIR into other apps that hold the
# `access_all_data` permission (e.g. the file-browser app), so a
# plaintext `admin-password.txt` here would be readable by them. That
# file is gone. `tootctl accounts create` still generates a random
# password internally (Mastodon requires one), but we capture it only
# long enough to confirm the create succeeded and then discard it — it
# never touches the filesystem. If the operator ever genuinely needs a
# password (e.g. to log in from a device that isn't behind OpenHost
# SSO), they reset one on demand from the OpenHost system terminal:
#
#     podman exec openhost-mastodon \
#         s6-setuidgid mastodon env HOME=/tmp \
#         /opt/mastodon/bin/tootctl accounts modify operator --reset-password
#
# Marker policy (load-bearing — get it wrong and operators end up with
# no admin and no auto-retry):
#
#   - On clean success (tootctl rc=0 AND a password line was parsed, so
#     we know the account was really created) we write the marker so
#     subsequent boots skip this section.
#   - If tootctl fails because the user already exists, we also write
#     the marker: retrying won't help.
#   - On any *other* failure we DO NOT write the marker, so the next
#     boot retries.
ADMIN_MARKER="$PERSIST/.admin-bootstrapped"
LEGACY_PW_FILE="$PERSIST/admin-password.txt"

# ----- owner username --------------------------------------------------
#
# The owner account username is the OpenHost zone owner's username,
# injected by the platform as OPENHOST_OWNER_USERNAME. We prefer that so
# the fediverse handle is @<you>@mastodon.<zone> instead of a generic
# "operator".
#
# Like the federation domain, a local account's username is PERMANENT
# once it federates — Mastodon has no rename. So we pin the value on
# first boot into a cache file and reuse it forever after, refusing to
# silently switch it if OPENHOST_OWNER_USERNAME later changes (which
# would otherwise create a SECOND account and leave the original
# orphaned). To change it you must wipe $OPENHOST_APP_DATA_DIR.
#
# Precedence: explicit ADMIN_USERNAME override > cached value from a
# prior boot > sanitized OPENHOST_OWNER_USERNAME > "owner".
#
# Mastodon usernames must match /\A[a-z0-9_]+\z/i and be <= 30 chars.
# We lowercase, replace every other character with '_', collapse
# repeats, trim leading/trailing underscores, and truncate. If the
# result is empty we fall back to "owner".
sanitize_username() {
    local raw="$1" out
    out="$(printf '%s' "$raw" \
        | tr '[:upper:]' '[:lower:]' \
        | sed -E 's/[^a-z0-9_]+/_/g; s/_+/_/g; s/^_+//; s/_+$//' \
        | cut -c1-30)"
    printf '%s' "$out"
}

USERNAME_CACHE_FILE="$PERSIST/owner-username"
if [[ -n "${ADMIN_USERNAME:-}" ]]; then
    ADMIN_USER="$(sanitize_username "$ADMIN_USERNAME")"
    log "using operator-provided ADMIN_USERNAME=$ADMIN_USER"
elif [[ -f "$USERNAME_CACHE_FILE" ]]; then
    ADMIN_USER="$(cat "$USERNAME_CACHE_FILE")"
    log "using cached owner username=$ADMIN_USER (do not change without wiping data)"
    if [[ -n "${OPENHOST_OWNER_USERNAME:-}" ]]; then
        EXPECTED="$(sanitize_username "$OPENHOST_OWNER_USERNAME")"
        if [[ -n "$EXPECTED" && "$EXPECTED" != "$ADMIN_USER" ]]; then
            log "WARNING: OPENHOST_OWNER_USERNAME sanitizes to '$EXPECTED' but cached username is '$ADMIN_USER'."
            log "WARNING: keeping the cached value. To change it, wipe \$OPENHOST_APP_DATA_DIR and redeploy."
        fi
    fi
elif [[ -f "$ADMIN_MARKER" ]]; then
    # MIGRATION PATH: an account was already bootstrapped by an earlier
    # build that predates the owner-username feature (username 'operator'
    # or 'owner'), but no username cache exists yet. We must NOT switch
    # the username to OPENHOST_OWNER_USERNAME now — Mastodon can't rename
    # a local account, so that would orphan the existing account and its
    # federation identity. Detect the existing owner account's real
    # username from the DB and pin THAT. New deploys never hit this
    # branch (no marker yet) and get OPENHOST_OWNER_USERNAME below.
    EXISTING_USER="$(s6-setuidgid postgres /usr/lib/postgresql/15/bin/psql \
        -h /var/run/postgresql -U postgres -d mastodon -tAc \
        "SELECT accounts.username FROM accounts
           JOIN users ON users.account_id = accounts.id
           JOIN user_roles ON user_roles.id = users.role_id
          WHERE accounts.domain IS NULL AND user_roles.name = 'Owner'
          ORDER BY accounts.id ASC LIMIT 1" 2>/dev/null | tr -d '[:space:]')"
    if [[ -z "$EXISTING_USER" ]]; then
        # No Owner-role account found (unusual). Fall back to the legacy
        # default this project shipped with.
        EXISTING_USER="operator"
    fi
    ADMIN_USER="$EXISTING_USER"
    log "existing deploy detected; pinning owner username to existing account '$ADMIN_USER' (Mastodon can't rename; wipe data to change)"
else
    ADMIN_USER="$(sanitize_username "${OPENHOST_OWNER_USERNAME:-}")"
    if [[ -z "$ADMIN_USER" ]]; then
        ADMIN_USER="owner"
        log "OPENHOST_OWNER_USERNAME unset/empty; defaulting owner username to 'owner'"
    else
        log "derived owner username=$ADMIN_USER from OPENHOST_OWNER_USERNAME"
    fi
fi

# Persist the pinned username so it's stable across boots.
printf '%s' "$ADMIN_USER" > "$USERNAME_CACHE_FILE"

ADMIN_EMAIL="${ADMIN_EMAIL:-${ADMIN_USER}@${LOCAL_DOMAIN}}"

# Scrub any plaintext password file left behind by an earlier build that
# persisted credentials. This runs on every boot so upgrading an
# existing deploy self-heals the leak.
if [[ -e "$LEGACY_PW_FILE" ]]; then
    log "removing legacy plaintext credentials file $LEGACY_PW_FILE (SSO makes it unnecessary)"
    rm -f "$LEGACY_PW_FILE"
fi

# Returns 0 on clean success, 2 if the user already exists, 1 on any
# other failure. Emits NOTHING sensitive to stdout — the generated
# password is parsed only to verify creation, then dropped on the floor.
bootstrap_admin() {
    local output rc password
    set +e
    # `--confirmed` marks the email confirmed (we can't deliver a
    # confirmation mail). `--approve` marks the account approved — this
    # is essential: on an instance with registrations closed (our
    # default), Mastodon's set_approved callback would otherwise leave a
    # tootctl-created account `approved: false`, and every authenticated
    # request would be bounced to /auth/edit ("pending review"). Both
    # confirmed AND approved are required for User#functional?.
    # `--role Owner` grants the highest permission level.
    output=$(mastodon_run /opt/mastodon/bin/tootctl accounts create "$ADMIN_USER" \
            --email "$ADMIN_EMAIL" \
            --confirmed \
            --approve \
            --role Owner 2>&1)
    rc=$?
    set -e

    if [[ $rc -eq 0 ]]; then
        # tootctl prints "OK\nNew password: <pw>" on success. We only
        # check that the password line exists as proof of creation; the
        # value itself is intentionally never captured into a variable
        # that outlives this function or written anywhere.
        if ! echo "$output" | grep -q '^New password: '; then
            log "tootctl returned 0 but did not print a password line; full output follows:"
            echo "$output" >&2
            return 1
        fi
        return 0
    fi

    if echo "$output" | grep -qiE "(Username|Email).*already been taken"; then
        log "tootctl reports admin user '$ADMIN_USER' already exists"
        return 2
    fi

    log "tootctl accounts create failed (exit $rc):"
    echo "$output" >&2
    return 1
}

if [[ -f "$ADMIN_MARKER" ]]; then
    log "admin user already bootstrapped; skipping"
else
    log "creating admin user '$ADMIN_USER' (email=$ADMIN_EMAIL)"
    # `--confirmed` skips the email confirmation flow we can't deliver.
    # `--role Owner` grants the highest permission level (Mastodon's
    # built-in role hierarchy: User < Moderator < Admin < Owner).
    set +e
    bootstrap_admin
    BOOTSTRAP_RC=$?
    set -e

    case "$BOOTSTRAP_RC" in
        0)
            touch "$ADMIN_MARKER"
            log "admin user '$ADMIN_USER' created; log in via OpenHost owner SSO"
            ;;
        2)
            touch "$ADMIN_MARKER"
            log "admin user '$ADMIN_USER' already exists; log in via OpenHost owner SSO"
            ;;
        *)
            log "WARN: admin bootstrap failed; will retry on next boot"
            log "WARN: marker NOT written"
            log "WARN: if this persists, run tootctl manually inside the container"
            ;;
    esac
fi

# ----- 7. ensure the owner account is functional (every boot) ------------
#
# Runs unconditionally (even when the create step above was skipped via
# the marker) so an account created by an older build — which did NOT
# pass --approve and is therefore stuck `approved: false` and bounced to
# /auth/edit on every request — is healed in place on the next deploy,
# with no data wipe. `tootctl accounts modify --confirm --approve` is
# idempotent: it's a no-op once the account is already confirmed +
# approved. Both flags are required for User#functional?, which is what
# gates access to the app after login.
#
# Non-fatal: if this fails (e.g. the account genuinely doesn't exist yet
# on a still-migrating first boot) we log and move on rather than block
# the longruns from starting.
if s6-setuidgid postgres /usr/lib/postgresql/15/bin/psql \
        -h /var/run/postgresql -U postgres -d mastodon -tAc \
        "SELECT 1 FROM accounts WHERE username='${ADMIN_USER}' AND domain IS NULL" \
        2>/dev/null | grep -q 1; then
    log "ensuring owner account '$ADMIN_USER' is confirmed + approved (idempotent)"
    set +e
    modify_out=$(mastodon_run /opt/mastodon/bin/tootctl accounts modify "$ADMIN_USER" \
            --confirm --approve 2>&1)
    modify_rc=$?
    set -e
    if [[ $modify_rc -ne 0 ]]; then
        log "WARN: could not confirm/approve '$ADMIN_USER' (exit $modify_rc):"
        echo "$modify_out" >&2
    fi
else
    log "owner account '$ADMIN_USER' not present yet; skipping confirm/approve"
fi

# ----- 8. first-boot content seeding (once) ------------------------------
#
# Give the owner something to look at out of the box: a welcome post, a
# friendly About description, and a few well-known fediverse accounts
# followed so the Home timeline fills in as federation catches up. This
# runs ONCE, gated by its own marker, and is entirely best-effort — a
# failure here (e.g. a remote server unreachable at boot) never blocks
# the app. After it runs, the instance behaves exactly like a normal
# Mastodon; the owner posts/follows/unfollows as usual.
#
# Gated separately from the admin marker so that on an upgrade of an
# instance that already had its admin bootstrapped (but never seeded) we
# still run the seed once. The seed script is itself idempotent (it
# checks for existing statuses / follows / description) as a second line
# of defence.
SEED_MARKER="$PERSIST/.seeded"
if [[ -f "$SEED_MARKER" ]]; then
    log "content already seeded; skipping"
elif [[ ! -f "$ADMIN_MARKER" ]]; then
    # Admin wasn't successfully bootstrapped this boot — don't seed
    # against a half-set-up instance; retry seeding next boot.
    log "admin not bootstrapped yet; deferring content seeding"
else
    log "seeding first-boot content (welcome post, About text, starter follows + backfill)"
    set +e
    seed_out=$(mastodon_run /usr/local/bin/bundle exec ruby /opt/openhost/seed.rb 2>&1)
    seed_rc=$?
    set -e
    # Surface the seed script's own [seed] log lines for visibility.
    echo "$seed_out" | grep -E '^\[seed\]' >&2 || true
    if [[ $seed_rc -eq 0 ]]; then
        touch "$SEED_MARKER"
        log "content seeding complete"
    else
        # Non-fatal. Leave the marker absent so we retry next boot; the
        # seed script is idempotent so a partial success won't duplicate.
        log "WARN: content seeding exited $seed_rc; will retry next boot"
        echo "$seed_out" | tail -5 >&2
    fi
fi

log "bootstrap complete"
