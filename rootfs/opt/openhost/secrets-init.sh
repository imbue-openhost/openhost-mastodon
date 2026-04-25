#!/command/with-contenv bash
# secrets-init: oneshot that generates Mastodon's persistent secrets on
# the first boot and exports them as env for the rest of the container.
#
# Mastodon needs a handful of cryptographic secrets that MUST be stable
# across container restarts — rotating them invalidates session cookies,
# breaks 2FA tokens, and orphans the web-push subscriptions every browser
# previously registered.
#
# Generated once on first boot, persisted to
# $OPENHOST_APP_DATA_DIR/mastodon-secrets.env, and read back on every
# subsequent boot. The file lives on the backed-up volume so a fresh
# deploy that happens to land on the same OpenHost data disk picks
# them right up.
#
# Secrets we own here:
#   SECRET_KEY_BASE      Rails session signing key
#   OTP_SECRET           2FA token derivation
#   VAPID_PRIVATE_KEY    Web Push (RFC 8292) — paired with public key
#   VAPID_PUBLIC_KEY     Browser-side public key for the same
#   ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY     Rails 7 encrypted attrs
#   ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY     (same)
#   ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT   (same)
#   POSTGRES_PASSWORD    Auto-generated; only relevant if DATABASE_URL
#                        ever switches to TCP auth.
#
# Secrets we do NOT own (set in env or by bootstrap):
#   LOCAL_DOMAIN / WEB_DOMAIN — derived at first request via the same
#                                X-Forwarded-Host trick as openhost-jitsi.
set -eu

log() { echo "[secrets-init] $*" >&2; }

PERSIST="${OPENHOST_APP_DATA_DIR:-/data/app_data/mastodon}"
SECRETS_FILE="$PERSIST/mastodon-secrets.env"

mkdir -p "$PERSIST"

if [[ -s "$SECRETS_FILE" ]]; then
    log "secrets already exist at $SECRETS_FILE; reusing"
else
    log "generating new secrets at $SECRETS_FILE"

    # Use openssl for a self-contained generation that doesn't require
    # the Ruby runtime to be ready (we run before any Rails process).
    # `bundle exec rake secret` and `mastodon:webpush:generate_vapid_key`
    # are the canonical generators, but they boot the full Rails app
    # which takes 20+ seconds. Doing it this way at first boot saves a
    # significant chunk of cold-start time.
    rand_hex() { openssl rand -hex "$1"; }

    # Mastodon's rake secret outputs a 128-character hex string (64
    # bytes). Match that exactly.
    SECRET_KEY_BASE_VAL=$(rand_hex 64)
    OTP_SECRET_VAL=$(rand_hex 64)

    # ActiveRecord's built-in encrypted attributes (Rails 7+, used by
    # Mastodon for OTP secrets and a few other columns). Each is a
    # 32-byte (64-hex-char) random value per Rails docs.
    AR_PRIMARY=$(rand_hex 16)
    AR_DETERMINISTIC=$(rand_hex 16)
    AR_SALT=$(rand_hex 16)

    # VAPID is an ECDSA P-256 keypair. Mastodon's
    # `mastodon:webpush:generate_vapid_key` rake task uses the
    # `webpush` gem which calls OpenSSL under the hood to mint a P-256
    # key and base64url-encode the raw scalar (private) and uncompressed
    # point (public). We replicate that here without needing Ruby.
    #
    # Steps:
    #  1. openssl ecparam -genkey -name prime256v1 -noout -outform PEM
    #  2. extract the 32-byte private scalar via `openssl ec -text`
    #  3. extract the 65-byte uncompressed public point the same way
    #  4. base64-url-encode (no padding) both
    TMP_PEM=$(mktemp)
    trap 'rm -f "$TMP_PEM"' EXIT

    openssl ecparam -genkey -name prime256v1 -noout -outform PEM > "$TMP_PEM"

    # Pull the hex-encoded private scalar and public point out of
    # `openssl ec -text`. Output looks like:
    #     priv:
    #         00:aa:bb:...
    #     pub:
    #         04:cc:dd:...
    EC_TEXT=$(openssl ec -in "$TMP_PEM" -text -noout 2>/dev/null)

    # Strip leading 00 (ASN.1 sign byte) on the private scalar if
    # present. Bash awk dance: lines between "priv:" and "pub:" exclusive.
    PRIV_HEX=$(echo "$EC_TEXT" \
        | awk '/priv:/{flag=1; next} /pub:/{flag=0} flag {print}' \
        | tr -d ' :\n')
    # OpenSSL emits a leading 00 if the high bit of the scalar is set
    # (DER ASN.1 INTEGER sign byte). Drop it so we always have exactly
    # 64 hex chars / 32 bytes.
    if [[ ${#PRIV_HEX} -eq 66 && "$PRIV_HEX" == 00* ]]; then
        PRIV_HEX="${PRIV_HEX:2}"
    fi

    PUB_HEX=$(echo "$EC_TEXT" \
        | awk '/pub:/{flag=1; next} /ASN1 OID:|NIST CURVE:/{flag=0} flag {print}' \
        | tr -d ' :\n')

    # base64url encode (RFC 4648 §5): swap +/ with -_, drop padding.
    b64url() {
        # xxd reverses hex → raw bytes. Then base64 with -w 0 (no
        # wrap), then character-class swap, then strip trailing =.
        xxd -r -p | base64 -w 0 | tr '+/' '-_' | tr -d '='
    }
    VAPID_PRIVATE_KEY_VAL=$(printf '%s' "$PRIV_HEX" | b64url)
    VAPID_PUBLIC_KEY_VAL=$(printf '%s' "$PUB_HEX"  | b64url)

    # Postgres password (random; only used if DATABASE_URL ever switches
    # to TCP auth or the Rails console connects via host: localhost).
    POSTGRES_PASSWORD_VAL=$(rand_hex 24)

    umask 077
    cat > "$SECRETS_FILE" <<EOF
# openhost-mastodon persistent secrets — DO NOT EDIT BY HAND.
# Regenerating these invalidates every existing session cookie and
# orphans every web-push subscription on every browser. The instance
# will keep working but federation handshakes that depend on the
# stored OAuth client secrets will need to be re-issued.
SECRET_KEY_BASE=$SECRET_KEY_BASE_VAL
OTP_SECRET=$OTP_SECRET_VAL
VAPID_PRIVATE_KEY=$VAPID_PRIVATE_KEY_VAL
VAPID_PUBLIC_KEY=$VAPID_PUBLIC_KEY_VAL
ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY=$AR_PRIMARY
ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY=$AR_DETERMINISTIC
ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT=$AR_SALT
POSTGRES_PASSWORD=$POSTGRES_PASSWORD_VAL
EOF
    chmod 0600 "$SECRETS_FILE"
fi

# Read back the file (whether we just wrote it or it already existed)
# and stamp every variable into the s6 container_environment so every
# downstream service inherits them via with-contenv.
#
# This is the s6-overlay v3 way of doing `set -a; source` for service
# scripts: write each name/value as a file under
# /run/s6/container_environment.
CENV=/run/s6/container_environment
mkdir -p "$CENV"
# shellcheck disable=SC2046
set -a
# shellcheck disable=SC1090
source "$SECRETS_FILE"
set +a

# Stamp each var. We deliberately enumerate (rather than reading the
# file again) so a typo in $SECRETS_FILE manifests as a missing var
# rather than silently passing through whatever happens to be in env.
for var in SECRET_KEY_BASE OTP_SECRET \
           VAPID_PRIVATE_KEY VAPID_PUBLIC_KEY \
           ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY \
           ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY \
           ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT \
           POSTGRES_PASSWORD; do
    val="${!var:-}"
    if [[ -z "$val" ]]; then
        log "FATAL: $var missing from $SECRETS_FILE"
        exit 1
    fi
    printf '%s' "$val" > "$CENV/$var"
    chmod 0600 "$CENV/$var"
done

log "secrets ready"
