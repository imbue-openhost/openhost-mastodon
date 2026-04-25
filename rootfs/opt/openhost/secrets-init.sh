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

# A previous container start may have written a *partial* secrets file
# and crashed before completing — that leaves us with a file that exists
# but is missing keys, and on every subsequent boot we'd reuse it and
# fail. Validate before reusing: the file must have all eight expected
# names, otherwise we throw it away and regenerate. The validation list
# matches the loop at the bottom of this script.
validate_secrets_file() {
    local f="$1"
    [[ -s "$f" ]] || return 1
    for name in SECRET_KEY_BASE OTP_SECRET \
                VAPID_PRIVATE_KEY VAPID_PUBLIC_KEY \
                ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY \
                ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY \
                ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT \
                POSTGRES_PASSWORD; do
        # `^NAME=.+` — non-empty value. The grep -E pattern is anchored
        # because we don't want a substring match (an entry that was
        # accidentally renamed `EXTRA_VAPID_PRIVATE_KEY=foo` shouldn't
        # validate as `VAPID_PRIVATE_KEY`).
        if ! grep -qE "^${name}=.+" "$f"; then
            return 1
        fi
    done
    return 0
}

if validate_secrets_file "$SECRETS_FILE"; then
    log "secrets already exist at $SECRETS_FILE; reusing"
else
    if [[ -e "$SECRETS_FILE" ]]; then
        log "existing secrets file at $SECRETS_FILE is incomplete; regenerating"
        # Move the partial out of the way so an operator can recover it
        # if they need to (e.g. the partial held the *real* SECRET_KEY_BASE
        # of an existing deploy and we'd otherwise lose all sessions).
        mv "$SECRETS_FILE" "$SECRETS_FILE.partial.$(date +%s)"
    fi
    log "generating new secrets"

    # All hex/base64 generation goes through Ruby. The Mastodon image's
    # ruby is in /usr/local/bin/ruby — we use it directly (no bundle exec
    # needed; OpenSSL + SecureRandom are stdlib). This is more
    # self-contained than chaining openssl + xxd + base64 + sed in shell,
    # and exactly mirrors what `rake secret` and the webpush gem do.
    #
    # Output format: one VAR=value per line on stdout. We capture the
    # whole block, validate it has all expected names, then write
    # atomically (tempfile + mv) so a crash mid-write can never leave a
    # partial file behind.
    RUBY=/usr/local/bin/ruby
    if ! command -v "$RUBY" >/dev/null 2>&1; then
        # Fall back to `ruby` on PATH if /usr/local/bin/ruby moved.
        RUBY=$(command -v ruby) || {
            log "FATAL: no ruby interpreter found (looked for /usr/local/bin/ruby and \$PATH ruby)"
            exit 1
        }
    fi

    # Heredoc to ruby. `securerandom.hex(64)` matches what `rake secret`
    # outputs (a 128-char hex string, 64 bytes of entropy). VAPID is an
    # ECDSA P-256 keypair; we extract the raw 32-byte scalar (private)
    # and 65-byte uncompressed point (public) and base64-url encode both
    # without padding, exactly matching the webpush gem's serialisation
    # at github.com/zaru/webpush/blob/v3.0/lib/webpush/vapid_key.rb
    NEW_SECRETS=$("$RUBY" <<'RUBY'
require 'securerandom'
require 'openssl'
require 'base64'

def b64url(bytes)
  Base64.urlsafe_encode64(bytes).delete('=')
end

# 64-byte hex = 128 chars. Mastodon's rake secret emits this format.
puts "SECRET_KEY_BASE=#{SecureRandom.hex(64)}"
puts "OTP_SECRET=#{SecureRandom.hex(64)}"
# Rails 7 ActiveRecord encryption: 32-char hex (16 bytes raw) per
# guides.rubyonrails.org/active_record_encryption.html.
puts "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY=#{SecureRandom.hex(16)}"
puts "ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY=#{SecureRandom.hex(16)}"
puts "ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT=#{SecureRandom.hex(16)}"
# Postgres password — used as a fallback if Mastodon ever connects via
# TCP. The local-socket path uses trust auth set up by pg-init.
puts "POSTGRES_PASSWORD=#{SecureRandom.hex(24)}"

# VAPID keypair (ECDSA P-256). The webpush gem writes:
#   private_key: base64url(big-endian bytes of the integer d)
#   public_key:  base64url(0x04 || X || Y)  -- uncompressed point, 65 bytes
key = OpenSSL::PKey::EC.generate('prime256v1')
priv_bn = key.private_key
# `to_s(2)` returns the raw big-endian magnitude. Pad to 32 bytes if
# the integer happened to be small (extremely rare for cryptographic
# random keys but cheap insurance — webpush expects exactly 32 bytes).
priv_bytes = priv_bn.to_s(2).rjust(32, "\x00".b)
pub_bytes  = key.public_key.to_octet_string(:uncompressed)

puts "VAPID_PRIVATE_KEY=#{b64url(priv_bytes)}"
puts "VAPID_PUBLIC_KEY=#{b64url(pub_bytes)}"
RUBY
)

    # Validate the captured block contains every name we'll insist on
    # below. If ruby errored in the middle of the heredoc, the catch is
    # here.
    for name in SECRET_KEY_BASE OTP_SECRET \
                VAPID_PRIVATE_KEY VAPID_PUBLIC_KEY \
                ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY \
                ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY \
                ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT \
                POSTGRES_PASSWORD; do
        if ! grep -qE "^${name}=.+" <<<"$NEW_SECRETS"; then
            log "FATAL: ruby secret generator did not emit $name"
            log "Output was:"
            echo "$NEW_SECRETS" >&2
            exit 1
        fi
    done

    # Atomic write: tempfile in the same directory (so mv is rename,
    # not copy), then mv into place. A crash between the tempfile
    # write and the rename leaves the previous (or no) file untouched.
    TMP_FILE="$SECRETS_FILE.tmp.$$"
    umask 077
    {
        echo "# openhost-mastodon persistent secrets — DO NOT EDIT BY HAND."
        echo "# Regenerating these invalidates every existing session cookie and"
        echo "# orphans every web-push subscription on every browser. The instance"
        echo "# will keep working but federation handshakes that depend on the"
        echo "# stored OAuth client secrets will need to be re-issued."
        echo "$NEW_SECRETS"
    } > "$TMP_FILE"
    chmod 0600 "$TMP_FILE"
    mv "$TMP_FILE" "$SECRETS_FILE"
fi

# Read back the file (whether we just wrote it or it already existed)
# and stamp every variable into /run/s6/container_environment so any
# service started via `with-contenv` inherits them.
#
# We do NOT `source` the file. Bootstrap.sh appends a runtime block to
# this same file with values like `SMTP_FROM_ADDRESS="Mastodon <...>"`
# that contain shell metacharacters; even with proper quoting, parse
# errors elsewhere in the file would abort the whole sourcing and
# prevent us from stamping the secrets. Instead we walk the file
# line-by-line, picking out only the names we care about.
CENV=/run/s6/container_environment
mkdir -p "$CENV"
extract_secret() {
    # First match wins. The regex tolerates either quoted or unquoted
    # values: `NAME=value`, `NAME="value"`, `NAME='value'`. We strip
    # surrounding quotes after matching.
    local name="$1"
    grep -E "^${name}=" "$SECRETS_FILE" | head -n1 \
        | sed -E "s/^${name}=//; s/^[\"']//; s/[\"']\$//"
}

for var in SECRET_KEY_BASE OTP_SECRET \
           VAPID_PRIVATE_KEY VAPID_PUBLIC_KEY \
           ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY \
           ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY \
           ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT \
           POSTGRES_PASSWORD; do
    val="$(extract_secret "$var")"
    if [[ -z "$val" ]]; then
        log "FATAL: $var missing from $SECRETS_FILE"
        exit 1
    fi
    printf '%s' "$val" > "$CENV/$var"
    chmod 0600 "$CENV/$var"
done

log "secrets ready"
