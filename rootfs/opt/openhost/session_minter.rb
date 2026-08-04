# frozen_string_literal: true

# session_minter.rb — warm-Rails SSO session minter for OpenHost.
#
# OpenHost's router authenticates the zone owner and stamps
# `X-OpenHost-Is-Owner: true` on the upstream request. Mastodon has no
# native way to consume that signal, so this sidecar bridges it: on an
# owner navigation the auth_proxy (auth_proxy.py) calls this minter over
# a loopback UNIX socket, and the minter hands back the exact pair of
# cookies a real password login would have set, so the owner lands in
# Mastodon already logged in as the bootstrap `operator` account.
#
# Why a warm Rails process instead of reproducing the cookie crypto in
# Python?
#
#   Mastodon's authenticated state is TWO Rails-protected cookies:
#
#     * `_mastodon_session` — the Warden session cookie (Rails 8
#       cookie_store, JSON serializer, AES-256-GCM authenticated
#       encryption keyed off SECRET_KEY_BASE). Its payload is the
#       Warden session hash `{"warden.user.user.key" => [[user.id],
#       user.authenticatable_salt]}`.
#
#     * `_session_id` — a Rails *signed* cookie whose value is the
#       `session_id` of a row in the `session_activations` table.
#       config/initializers/devise.rb's after_fetch hook logs the user
#       out unless this cookie is present AND a matching row exists, so
#       both halves are mandatory.
#
#   Reproducing AES-GCM + ActiveSupport::KeyGenerator PBKDF2 salts +
#   Rails' purpose-metadata framing in Python is a maintenance
#   liability that silently breaks on any Rails cookie-format bump.
#   Instead we boot Rails ONCE (~10 s at container start, then stays
#   warm) and mint cookies through Rails' own ActionDispatch cookie jar
#   — byte-identical to what a browser login produces, and correct by
#   construction across upgrades.
#
# Protocol (deliberately tiny — no HTTP framework, just a line):
#
#   The auth_proxy connects to the UNIX socket at $MINTER_SOCK, writes a
#   single request line, and reads a single JSON response line.
#
#     Request : "MINT <remote_ip> <url-encoded user-agent>\n"
#     Response: {"ok":true,"cookies":[{"name":..,"value":..,
#                "max_age":..}, ...]}  OR  {"ok":false,"error":".."}
#
#   The minter creates a fresh SessionActivation row per request (same
#   as a real login) and returns the two Set-Cookie payloads. The
#   auth_proxy is responsible for turning those into Set-Cookie headers
#   with the right flags and 302'ing the visitor back to their URL.
#
# Security notes:
#
#   * The socket is created 0600 owned by `mastodon`; only the
#     auth_proxy (also running as `mastodon`) can talk to it. It is
#     never exposed off-loopback.
#   * The minter only ever mints for the single Owner account created
#     at bootstrap. It refuses if it cannot find exactly one usable
#     Owner. It performs NO credential check itself — the trust anchor
#     is the auth_proxy having already verified `X-OpenHost-Is-Owner`,
#     which only the OpenHost router can set.
#   * Nothing is written to disk. The only artifact is a session row in
#     Postgres, which is exactly what a normal login creates and which
#     the owner can revoke from Preferences → Account → Sessions.

require '/opt/mastodon/config/environment'

require 'socket'
require 'json'
require 'fileutils'
require 'securerandom'
require 'cgi'
require 'stringio'

SOCK_PATH = ENV.fetch('MINTER_SOCK', '/run/mastodon/minter.sock')

# ---------------------------------------------------------------------------
# Owner resolution
# ---------------------------------------------------------------------------
#
# The bootstrap creates a single Owner-role account (username defaults
# to `operator`). We resolve the owner the same way Mastodon's admin UI
# thinks about it: the user whose role is (or inherits) the highest
# built-in permission. We pick the lowest-id confirmed user holding a
# role with the Owner permission flag, which is deterministic and
# matches the bootstrap account on a single-user instance.
#
# We memoise the id (not the object) so a password change — which
# rotates authenticatable_salt — is always reflected, because we reload
# the User row on every mint.
def owner_user_id
  @owner_user_id ||= begin
    owner_role_ids = UserRole.where('(permissions & ?) > 0', UserRole::FLAGS[:administrator])
                             .or(UserRole.where(name: 'Owner'))
                             .pluck(:id)

    scope = User.confirmed
    scope = scope.where(role_id: owner_role_ids) if owner_role_ids.any?
    user  = scope.order(:id).first

    # Fall back to the explicitly configured bootstrap username if the
    # role query found nothing (e.g. a very old build that created the
    # account before roles were seeded).
    user ||= begin
      username = ENV['ADMIN_USERNAME'].presence || 'operator'
      account  = Account.local.find_by(username: username)
      account&.user
    end

    raise 'no owner account found' if user.nil?

    user.id
  end
end

# ---------------------------------------------------------------------------
# Cookie minting
# ---------------------------------------------------------------------------
#
# We drive Rails' real ActionDispatch cookie jar. We build a minimal
# rack env carrying the app's key generator + cookie config (exactly
# what a live request carries), assign into the encrypted and signed
# jars the same way Warden's after_set_user hook and devise.rb do, then
# read back the serialized Set-Cookie strings.
def build_cookie_env(remote_ip)
  # Rails.application.env_config already contains every `action_dispatch.*`
  # header the Cookies middleware injects into a live request (the
  # key_generator, all the cookie salts, secret_key_base, the serializer,
  # rotations, same-site proc, and the use_cookies_with_metadata flag).
  # We start from a dup of that so our cookie crypto is provably identical
  # to what the puma web process produces — no hand-picked subset of
  # config accessors to drift out of sync on a Rails upgrade.
  env = Rails.application.env_config.dup

  env['HTTP_HOST']       = (ENV['LOCAL_DOMAIN'].presence || 'localhost')
  env['REMOTE_ADDR']     = remote_ip
  env['rack.input']      = StringIO.new('')
  env['REQUEST_METHOD']  = 'GET'
  env['SCRIPT_NAME']     = ''
  env['PATH_INFO']       = '/'
  # Mark the synthetic request as HTTPS so CookieJar#write_cookie? and any
  # secure-cookie logic behave the same as behind the OpenHost router's
  # TLS front-end. (We read the serialized value straight back out of the
  # jar rather than through #write, but keep this consistent regardless.)
  env['HTTPS']           = 'on'
  env['rack.url_scheme'] = 'https'

  # Defensive: if for any reason env_config didn't carry the key
  # generator / secret (e.g. a future Rails reshuffles when middleware
  # runs), fill the two load-bearing ones from the application directly.
  env[ActionDispatch::Cookies::GENERATOR_KEY] ||= Rails.application.key_generator
  env[ActionDispatch::Cookies::SECRET_KEY_BASE] ||= Rails.application.secret_key_base

  env
end

def mint_cookies(remote_ip, user_agent)
  user = User.find(owner_user_id)

  # 1. Create the SessionActivation row exactly like User#activate_session
  #    (config/initializers/devise.rb's after_set_user hook does this on a
  #    real login). We can't call activate_session directly because it
  #    wants an ActionDispatch::Request; the model call underneath is a
  #    plain create!, so we mirror it.
  session_id = SecureRandom.hex
  user.session_activations.create!(
    session_id: session_id,
    user_agent: user_agent.to_s[0, 255],
    ip: remote_ip
  )
  # Enforce Mastodon's session cap the same way the model does.
  user.session_activations.latest
      .offset(Rails.configuration.x.max_session_activations)
      .destroy_all

  env = build_cookie_env(remote_ip)
  jar = ActionDispatch::Request.new(env).cookie_jar

  # 2. _mastodon_session — the Warden session cookie.
  #
  #    Rails' ActionDispatch::Session::CookieStore serializes the session
  #    HASH into this cookie and writes it via
  #    `request.cookie_jar.signed_or_encrypted` (encrypted when
  #    secret_key_base is set, which it always is here). The stored hash
  #    is the raw Rack session with two things in it:
  #
  #      * "warden.user.user.key" => [record.to_key,
  #        record.authenticatable_salt]  (Warden/Devise's
  #        serialize_into_session for the :user scope), and
  #      * "session_id" => <random public id>  (Rails' own internal
  #        session id that CookieStore#write_session always injects; it
  #        is distinct from the _session_id cookie below).
  #
  #    We reproduce that exact envelope and write it through the same
  #    signed_or_encrypted jar CookieStore uses, so the cookie is
  #    byte-compatible with one a browser login would receive.
  session_key   = 'warden.user.user.key'
  session_value = [user.to_key, user.authenticatable_salt]

  jar.signed_or_encrypted['_mastodon_session'] = {
    value: {
      session_key => session_value,
      'session_id' => SecureRandom.hex(16),
    },
    expires: 1.year.from_now,
    httponly: true,
    same_site: :lax,
  }

  # 3. _session_id — the Rails *signed* cookie whose value is the
  #    session_activations.session_id (see devise.rb after_set_user).
  jar.signed['_session_id'] = {
    value: session_id,
    expires: 1.year.from_now,
    httponly: true,
    same_site: :lax,
  }

  # Read back the fully-serialized (encrypted / signed) cookie values
  # Rails produced. AbstractCookieJar#[]= writes the committed value into
  # the parent CookieJar's @cookies map, which CookieJar exposes via its
  # Enumerable #each, so we can read them without poking at ivars.
  cookies = []
  jar.each do |name, value|
    next unless %w[_mastodon_session _session_id].include?(name)
    cookies << { 'name' => name, 'value' => value, 'max_age' => 31_556_952 } # 1y
  end

  unless cookies.length == 2
    raise "expected 2 cookies, jar produced #{cookies.map { |c| c['name'] }.inspect}"
  end

  { 'ok' => true, 'cookies' => cookies }
end

# ---------------------------------------------------------------------------
# Socket server
# ---------------------------------------------------------------------------

def serve
  FileUtils.mkdir_p(File.dirname(SOCK_PATH))
  File.delete(SOCK_PATH) if File.exist?(SOCK_PATH)

  server = UNIXServer.new(SOCK_PATH)
  File.chmod(0o600, SOCK_PATH)

  # Signal readiness to the log so the s6 readiness gate (and humans
  # watching first-boot) can see the ~10s Rails boot finished.
  warn '[session-minter] ready; listening on ' + SOCK_PATH
  $stderr.flush

  loop do
    conn = server.accept
    begin
      line = conn.gets
      next if line.nil?

      parts = line.strip.split(' ', 3)
      if parts[0] != 'MINT'
        conn.puts(JSON.generate('ok' => false, 'error' => 'bad request'))
        next
      end

      remote_ip  = parts[1].to_s.empty? ? '127.0.0.1' : parts[1]
      user_agent = parts[2].to_s.empty? ? '' : CGI.unescape(parts[2])

      begin
        result = mint_cookies(remote_ip, user_agent)
      rescue => e
        warn "[session-minter] mint failed: #{e.class}: #{e.message}"
        result = { 'ok' => false, 'error' => "#{e.class}: #{e.message}" }
      end

      conn.puts(JSON.generate(result))
    rescue => e
      warn "[session-minter] connection error: #{e.class}: #{e.message}"
    ensure
      conn.close rescue nil
    end
  end
end

serve
