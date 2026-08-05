# openhost-mastodon

[Mastodon](https://joinmastodon.org/) packaged as an OpenHost app.

Bundles all five processes Mastodon's standard production deploy needs
— PostgreSQL, Redis, Puma (web), Sidekiq (background workers), and the
Node streaming server — plus a Caddy front-door and an OpenHost SSO
sidecar, into a single container supervised by
[s6-overlay v3](https://github.com/just-containers/s6-overlay).

## TL;DR

Deploy via the OpenHost router. Once it's up, just open
`https://mastodon.<your-zone>` **as the zone owner** — OpenHost SSO
logs you straight in as the instance admin (`operator`). No password to
copy, nothing to read out of the container. Start posting. See
[Owner SSO](#owner-sso) for how it works and how to recover a password
if you ever need one for a non-SSO device.

## ⚠ Caveats — read these before deploying

### Federation identity is permanent

Mastodon embeds the canonical hostname of the instance into every
ActivityPub object it federates: actor URIs, post IDs, follower
collections. Once your instance has handshaked with **any** remote
Mastodon server, that hostname is **forever** the only valid identity
for it. You cannot rename the instance without breaking every existing
follower relationship and every cached post on every remote server
that ever interacted with you.

This wrapper pins the federation identity to
`{OPENHOST_APP_NAME}.{OPENHOST_ZONE_DOMAIN}` (e.g.
`mastodon.zack.host.imbue.com`) on the very first boot and writes that
value to `$OPENHOST_APP_DATA_DIR/local-domain`. Subsequent boots load
from the cache and refuse to silently change it. If you ever need to
change the domain, **wipe `$OPENHOST_APP_DATA_DIR` and start over** —
all posts, followers, and migrations will be lost.

### SMTP is unconfigured

Mastodon needs SMTP for user signup confirmations, password resets,
2FA recovery, and report notifications. This wrapper boots with
`SMTP_DELIVERY_METHOD=test` (mail goes to `/dev/null`) so the Rails
app boots without a real SMTP server.

Consequences:

- **Public signups silently fail.** New users hit `/auth/sign_up`,
  enter their email, and never receive the confirmation. The account
  exists in the DB but cannot log in.
- **Password reset is unavailable** for any user who is not the
  bootstrap admin (the admin's password is in
  `admin-password.txt`).
- **Report notifications go nowhere.**

For an actual fediverse presence, configure SMTP via env vars before
deploying — see the `SMTP_*` block in `bootstrap.sh`. For a test
instance you only intend to log into yourself, the defaults are fine.

### This is heavy

The `[resources]` block declares 3 GB of memory and 2 CPU cores. That
is the practical floor for a single-user instance: Postgres alone
takes ~256 MB shared_buffers, the puma master plus 2 workers takes
~700 MB, sidekiq another ~400 MB, the streaming Node process ~150 MB,
Redis ~50 MB, plus libvips/ffmpeg media processing spikes during
attachment uploads. **There is no slack.** A multi-user instance under
real federation load will OOM at this allocation.

### Anyone with the URL can read public posts

`public_paths = ["/"]` in `openhost.toml` — the OpenHost owner-auth
gate is **disabled** because federation requests come from random
remote Mastodon instances and must not be challenged. The web UI is
also fully public; account-level privacy is enforced by Mastodon's
own session/cookie auth on top.

This is normal for a Mastodon instance. If you want a private fedi
presence, look at making your account "locked" (manual follower
approval) or at disabling federation entirely via the
`LIMITED_FEDERATION_MODE=true` env var (relays + ActivityPub still
work, but you only see what your followed accounts post).

## Architecture

```
   browser
      │  https (443)                         streaming wss
      │                                       (same vhost)
      ▼
   OpenHost router  ─ http :8080 ─▶  auth-proxy (SSO front-door)
     (stamps                            │
   X-OpenHost-Is-Owner)   owner HTML nav │ (no session) ──▶ session-minter
                                         │                    (UNIX socket,
                                         │                     warm Rails)
                          everything ────┼──▶ Caddy :8090
                                         │      │
                     /api/v1/streaming/* ┼──────┼──▶ node :4000
                     everything else ────┴──────┴──▶ puma :3000
                                                       │
                                                       ▼
                                              Sidekiq (no port)
                                                       │
                                                       ▼
                                   Postgres (uds) ◀────┴────▶ Redis (loopback :6379)
```

Nine processes (postgres, redis, caddy, puma, sidekiq, node streaming,
the auth-proxy SSO front-door, the session-minter, plus s6-overlay's
supervisor) live in the same container. s6-rc dependency tracking
enforces startup order:

1. `pg-init` (oneshot) — initdb on first boot, no-op afterwards.
2. `secrets-init` (oneshot) — generate SECRET_KEY_BASE, OTP_SECRET,
   VAPID keypair, postgres password on first boot; load them into
   `/run/s6/container_environment` on every boot.
3. `postgres` + `redis` (longruns) — start in parallel.
4. `bootstrap` (oneshot) — depends on postgres, redis, and
   secrets-init. Waits for postgres to accept connections, creates the
   `mastodon` role + database, runs `db:migrate`, and on the first
   boot creates the `operator` Owner account via `tootctl` (the
   generated password is discarded, never written to disk — see
   [Owner SSO](#owner-sso)).
5. `caddy`, `mastodon-web`, `mastodon-streaming`, `mastodon-sidekiq`,
   `session-minter` (longruns) — start in parallel after bootstrap
   exits 0. The `session-minter` boots Rails once (~10 s) and then
   serves cookie-mint requests over a loopback UNIX socket.
6. `auth-proxy` (longrun) — the public front-door on :8080. Depends on
   `caddy`. It reverse-proxies everything to Caddy on :8090 and adds
   OpenHost owner auto-login (see [Owner SSO](#owner-sso)).

If any longrun crashes, s6 restarts it in place; `bootstrap` only
runs once per container start.

### Owner SSO

The OpenHost router authenticates the zone owner and stamps
`X-OpenHost-Is-Owner: true` on the upstream request. On the owner's
first top-level HTML navigation that doesn't already carry a Mastodon
session cookie, the `auth-proxy` asks the `session-minter` to create a
real Mastodon login session for the `operator` account and 302s the
owner back to the URL they asked for with the minted
`_mastodon_session` + `_session_id` cookies. From then on Mastodon's
own session carries them.

The minter boots Rails once and mints those cookies through Rails' own
`ActionDispatch` cookie jar and Devise/Warden serialization, so they
are byte-identical to what a browser password login produces — we
never reimplement Rails cookie crypto outside Rails, and the mechanism
stays correct across Mastodon/Rails upgrades. The only artifact is a
`session_activations` row in Postgres, exactly like a normal login;
the owner can revoke it from **Preferences → Account → Sessions**.

Everything that is *not* an owner HTML navigation — federation inbox
deliveries, WebFinger, ActivityPub actor fetches, the streaming
WebSocket, anonymous visitors reading public posts, non-owner logged-in
users — flows straight through the auth-proxy untouched. The
auto-login path is gated on `X-OpenHost-Is-Owner`, which only the
OpenHost router can set, so remote/anonymous traffic can never trigger
it.

## First boot is slow

Allow 5–10 minutes for the container to come up the first time. On
the first boot:

- `initdb` runs (~5s).
- `db:migrate` walks ~250 migrations from `2016_02_20_174730` to
  current (~60–90s).
- `tootctl accounts create` boots Rails and creates the `operator`
  Owner account (~30s of just Rails boot time).
- The `session-minter` boots a second Rails instance (~10s) before
  owner SSO is available. Until it's up, an owner visit falls back to
  Mastodon's normal login form; it starts working on its own once the
  minter finishes booting.
- The bundled image cold-loads ~250 MB of gem code into RAM.

You can watch progress with `GET /app_logs/mastodon` from the
OpenHost API or via the in-host terminal.

## Persistent data

```
$OPENHOST_APP_DATA_DIR/
├── postgres/                  # PGDATA. Mastodon's whole world.
├── redis/                     # RDB snapshots.
├── mastodon-uploads/          # Avatars, attachments, custom emoji.
│                              # Symlinked from /opt/mastodon/public/system.
├── mastodon-secrets.env       # Generated once on first boot.
│                              # SECRET_KEY_BASE, OTP_SECRET, VAPID
│                              # keypair, postgres password.
├── local-domain               # The federation identity. PERMANENT.
└── .admin-bootstrapped        # Marker so admin creation runs once.
```

Everything in here is on the OpenHost-backed-up volume.

> **No credentials on disk.** Earlier builds wrote the admin password
> to `admin-password.txt` here. That was a credential-leak risk —
> OpenHost bind-mounts this directory into other apps that hold the
> `access_all_data` permission (e.g. the file-browser app), so the
> plaintext password was readable by them. That file is gone: the
> owner logs in via SSO and the bootstrap discards the generated
> password instead of persisting it. On upgrade, any legacy
> `admin-password.txt` left by an old build is deleted automatically
> on the next boot. (`mastodon-secrets.env` remains — it holds
> SECRET_KEY_BASE and the postgres password, which are only useful to
> someone who already has database access, and rotating them would
> invalidate every session and break web-push. It is `0600`.)

## Logging in as admin

Just open `https://mastodon.<your-zone>` **as the zone owner**. The
OpenHost router recognises you and the app's SSO sidecar logs you
straight in as the `operator` Owner account — no password, nothing to
copy out of the container. See [Owner SSO](#owner-sso) for the
mechanics.

The account username is `operator` (Mastodon reserves `admin`, so we
use `operator` like the openhost-forgejo wrapper does).

### I need a password (non-SSO device / API tooling)

The `operator` account has no known password by design — SSO doesn't
need one. If you genuinely need to log in from somewhere that isn't
behind OpenHost owner auth, mint a password on demand from the
OpenHost system terminal:

```sh
podman exec openhost-mastodon \
    s6-setuidgid mastodon env HOME=/tmp \
    /opt/mastodon/bin/tootctl accounts modify operator --reset-password
```

`tootctl` prints the new password to stdout (it is not written to
disk). Log in with it at `https://mastodon.<your-zone>/auth/sign_in`
using the email `operator@mastodon.<your-zone>`, then change it from
**Preferences → Account → Change password**.

### Owner SSO isn't logging me in

1. **The session-minter is still booting.** First boot needs ~10 s of
   extra Rails cold-boot before SSO is live; until then owners see the
   normal login form. Wait for `app_logs/mastodon` to show
   `[session-minter] ready` and try again.

2. **You're not visiting as the zone owner.** SSO only fires for the
   authenticated OpenHost owner (the router stamps
   `X-OpenHost-Is-Owner: true`). Anonymous visitors and remote
   fediverse servers deliberately never get auto-logged-in.

## Configuration knobs

Mostly via env vars set in `openhost.toml` or by editing the runtime
ENV block in the Dockerfile:

| Env var | Default | Notes |
|---------|---------|-------|
| `LOCAL_DOMAIN` | derived from OpenHost env | Federation identity. **Setting this manually overrides the cache file** — only do this on a brand-new deploy. |
| `WEB_DOMAIN` | same as `LOCAL_DOMAIN` | If you want the web UI on a separate hostname. Has its own caveats; see Mastodon docs. |
| `SMTP_DELIVERY_METHOD` | `test` | Set to `smtp` and configure `SMTP_SERVER`, `SMTP_LOGIN`, `SMTP_PASSWORD`, etc. to send real mail. |
| `DEFAULT_LOCALE` | `en` | Two-letter language code. |
| `ADMIN_USERNAME` / `ADMIN_EMAIL` | `operator` / `operator@<domain>` | Only effective on the first boot. |
| `LIMITED_FEDERATION_MODE` | (unset) | Set to `true` to disable outbound federation. |

## Files

- `Dockerfile` — multi-stage. Pulls the upstream Mastodon Ruby image
  as base, the Mastodon streaming Node image for `/opt/mastodon-streaming`,
  installs postgres-15, redis, caddy, python3, and s6-overlay v3 from apt.
- `openhost.toml` — OpenHost manifest. `public_paths = ["/"]`, 3 GB
  RAM, 2 CPUs.
- `rootfs/etc/s6-overlay/s6-rc.d/*` — service definitions. One dir
  per supervised service; `type` + `run` (longruns) or `up` (oneshots).
- `rootfs/opt/openhost/{pg-init,secrets-init,bootstrap}.sh` — the
  three first-boot scripts.
- `rootfs/opt/openhost/auth_proxy.py` — the SSO front-door on :8080.
  Reverse-proxies to Caddy; adds OpenHost owner auto-login. Stdlib
  Python only.
- `rootfs/opt/openhost/session_minter.rb` — warm-Rails cookie minter.
  Turns an `X-OpenHost-Is-Owner` navigation into a real Mastodon
  session for `operator` by minting `_mastodon_session` + `_session_id`
  through Rails' own cookie jar. Listens on a loopback UNIX socket.
- `rootfs/etc/caddy/Caddyfile` — listens on :8090 behind the
  auth-proxy; splits `/api/v1/streaming` to node, everything else to
  puma; rewrites Host from X-Forwarded-Host.

## Limitations / future work

- **No Elasticsearch.** Mastodon's full-text search across statuses
  and accounts requires Elasticsearch. We don't bundle it (would
  push memory past 4 GB) — search falls back to the Postgres trigram
  index, which only matches accounts and hashtags, not post bodies.
- **No object storage.** Uploads are on the local persisted volume.
  Fine for a small instance; for any meaningful traffic you'd want
  S3-compatible storage configured via `S3_ENABLED=true` + the
  related env vars.
- **No CDN.** Public/system uploads are served by puma, which is not
  what Mastodon recommends for production.
- **No Tor / hidden-service routing.** The official compose has
  optional `tor:` + `privoxy:` services for federating with .onion
  instances. Skipped here.

## Licensing

Mastodon is AGPL-3.0-or-later. This wrapper is distributed under the
same license.
