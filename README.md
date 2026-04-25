# openhost-mastodon

[Mastodon](https://joinmastodon.org/) packaged as an OpenHost app.

Bundles all five processes Mastodon's standard production deploy needs
— PostgreSQL, Redis, Puma (web), Sidekiq (background workers), and the
Node streaming server — plus a Caddy front-door, into a single
container supervised by [s6-overlay v3](https://github.com/just-containers/s6-overlay).

## TL;DR

Deploy via the OpenHost router. Once it's up, the admin password is in
`$OPENHOST_APP_DATA_DIR/admin-password.txt` *inside the container*. The
simplest way to read it is `podman exec` from the OpenHost system
terminal — see [Logging in as admin](#logging-in-as-admin) for the
exact command. Then log in at `https://mastodon.<your-zone>` and
start posting.

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
   OpenHost router  ──── http :8080 ────▶  Caddy (in container)
                                              │
                       /api/v1/streaming/* ───┼──▶ node :4000
                       everything else  ─────┴──▶ puma :3000
                                                      │
                                                      ▼
                                             Sidekiq (no port)
                                                      │
                                                      ▼
                                  Postgres (uds) ◀────┴────▶ Redis (loopback :6379)
```

All seven processes (postgres, redis, caddy, puma, sidekiq, node
streaming, plus s6-overlay's supervisor) live in the same container.
s6-rc dependency tracking enforces startup order:

1. `pg-init` (oneshot) — initdb on first boot, no-op afterwards.
2. `secrets-init` (oneshot) — generate SECRET_KEY_BASE, OTP_SECRET,
   VAPID keypair, postgres password on first boot; load them into
   `/run/s6/container_environment` on every boot.
3. `postgres` + `redis` (longruns) — start in parallel.
4. `bootstrap` (oneshot) — depends on postgres, redis, and
   secrets-init. Waits for postgres to accept connections, creates the
   `mastodon` role + database, runs `db:migrate`, and on the first
   boot creates the admin user via `tootctl` and stashes the
   generated password to `admin-password.txt`.
5. `caddy`, `mastodon-web`, `mastodon-streaming`, `mastodon-sidekiq`
   (longruns) — start in parallel after bootstrap exits 0.

If any longrun crashes, s6 restarts it in place; `bootstrap` only
runs once per container start.

## First boot is slow

Allow 5–10 minutes for the container to come up the first time. On
the first boot:

- `initdb` runs (~5s).
- `db:migrate` walks ~250 migrations from `2016_02_20_174730` to
  current (~60–90s).
- `tootctl accounts create` boots Rails and creates the admin user
  (~30s of just Rails boot time).
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
├── admin-password.txt         # First-boot admin credentials. 0600.
└── .admin-bootstrapped        # Marker so admin creation runs once.
```

Everything in here is on the OpenHost-backed-up volume.

## Logging in as admin

The bootstrap script writes the admin password to
`$OPENHOST_APP_DATA_DIR/admin-password.txt` after the first successful
boot. That env var resolves to `/data/app_data/mastodon/...` *inside
the container*, but the bind-mounted host path varies per OpenHost
install (e.g.  `/home/host/.openhost/local_compute_space/persistent_data/app_data/mastodon/`
on a default Ansible-provisioned VM, somewhere else on a custom
install). The container's view is always the same, so the
recommended way to read the file is to exec into the container from
the OpenHost system terminal:

```sh
podman exec openhost-mastodon \
    cat /data/app_data/mastodon/admin-password.txt
```

If you prefer to read it from the host directly, find the host path
once with:

```sh
podman inspect openhost-mastodon \
    --format '{{ range .Mounts }}{{ if eq .Destination "/data/app_data/mastodon" }}{{ .Source }}{{ end }}{{ end }}'
```

and `cat $THAT_PATH/admin-password.txt`.

> Note: `GET /app_logs/<app>` does **not** reliably contain the
> bootstrap script's output. Bootstrap is an s6-overlay oneshot and
> its stderr is not always plumbed into the same log podman shows
> for the longruns. Use the file, not the log endpoint.

The username is `operator` (Mastodon reserves `admin` so we use
`operator` like the openhost-forgejo wrapper does). Log in at
`https://mastodon.<your-zone>/auth/sign_in` with the email
`operator@mastodon.<your-zone>` and the printed password. Change the
password from **Preferences → Account → Change password** on first
login and remove the file from `$OPENHOST_APP_DATA_DIR`.

### What if `admin-password.txt` is missing?

If the file is absent on a running instance, one of two things has
happened:

1. **The bootstrap is still in progress.** First boot can take 5–10
   minutes (db:migrate runs ~250 migrations + Rails cold-boot for
   tootctl). Wait for `app_logs/mastodon` to show puma serving
   requests, then check again.

2. **The bootstrap is finished and the file was never written.** This
   was a real bug in earlier builds: the marker file
   (`.admin-bootstrapped`) could be written even when admin creation
   silently failed, leaving the instance with no working admin and
   no auto-retry. Newer builds detect this and write a placeholder
   `admin-password.txt` containing the recovery instructions, but if
   you're on an old build the file is just missing.

   To recover, approve the account and reset its password from the
   OpenHost system terminal. The two are independent — without
   `accounts approve` you'll log in and immediately land on
   Mastodon's "Your application is pending review by our staff"
   page, regardless of whether the password works:

   ```sh
   # Approve the account (idempotent if already approved).
   podman exec openhost-mastodon \
       /command/s6-setuidgid mastodon env HOME=/tmp \
       /opt/mastodon/bin/tootctl accounts approve operator

   # Reset password (or create the user if it never existed).
   podman exec openhost-mastodon \
       /command/s6-setuidgid mastodon env HOME=/tmp \
       /opt/mastodon/bin/tootctl accounts modify operator --reset-password \
   || podman exec openhost-mastodon \
       /command/s6-setuidgid mastodon env HOME=/tmp \
       /opt/mastodon/bin/tootctl accounts create operator \
           --email operator@$LOCAL_DOMAIN \
           --confirmed --approve --role Owner
   ```

   tootctl prints the new password to stdout on the second command.
   Log in with it, change it from Preferences → Account → Change
   password, and you're back in business.

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
  installs postgres-15, redis, caddy, and s6-overlay v3 from apt.
- `openhost.toml` — OpenHost manifest. `public_paths = ["/"]`, 3 GB
  RAM, 2 CPUs.
- `rootfs/etc/s6-overlay/s6-rc.d/*` — service definitions. One dir
  per supervised service; `type` + `run` (longruns) or `up` (oneshots).
- `rootfs/opt/openhost/{pg-init,secrets-init,bootstrap}.sh` — the
  three first-boot scripts.
- `rootfs/etc/caddy/Caddyfile` — splits `/api/v1/streaming` to node,
  everything else to puma; rewrites Host from X-Forwarded-Host.

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
