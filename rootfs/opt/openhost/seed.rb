# frozen_string_literal: true

# seed.rb — first-boot content seeding for a fresh OpenHost Mastodon.
#
# A brand-new single-user Mastodon is an empty void: no posts, an empty
# Home timeline, a blank About page. This script gives the owner
# something to look at out of the box while leaving the instance fully
# usable as normal afterwards. It is deliberately conservative:
#
#   * It runs ONCE, gated by a marker file in $OPENHOST_APP_DATA_DIR.
#     After the first successful run it never touches your instance
#     again, so it can't fight your own posting/following later.
#   * Every individual seed action is best-effort and independently
#     wrapped: a failure to resolve a remote account (network hiccup,
#     the remote instance being down at boot) logs a warning and moves
#     on. Seeding never blocks the app from starting or the owner from
#     using it.
#   * It only ever acts as the local `operator` owner account.
#
# What it seeds:
#   1. A friendly server short-description (About page) — only if the
#      admin hasn't already set one.
#   2. A welcome post from the owner, so the profile + local timeline
#      aren't blank.
#   3. A handful of well-known, high-signal fediverse accounts the
#      owner follows, so the Home timeline fills with real content once
#      federation catches up (async — posts trickle in over the next
#      few minutes as the remote servers deliver).
#
# The follows are the load-bearing bit: they turn an empty Home
# timeline into a live feed without the owner having to know who to
# follow on day one. The owner can unfollow any of them normally.

require '/opt/mastodon/config/environment'

def log(msg)
  warn "[seed] #{msg}"
  $stderr.flush
end

ADMIN_USERNAME = (ENV['ADMIN_USERNAME'].presence || 'operator')

# Resolve the local owner account (same logic the minter uses: the
# local account matching the bootstrap username).
owner = Account.local.find_by(username: ADMIN_USERNAME)
if owner.nil?
  log "owner account '#{ADMIN_USERNAME}' not found; nothing to seed"
  exit 0
end

# ---------------------------------------------------------------------------
# 1. Server short description (About page) — only if unset.
# ---------------------------------------------------------------------------
begin
  if Setting.site_short_description.blank?
    Setting.site_short_description =
      'A personal Mastodon instance hosted on OpenHost. ' \
      'Federated microblogging — follow people across the fediverse, ' \
      'post your own updates, own your data.'
    log 'set default site short description'
  else
    log 'site short description already set; leaving it'
  end
rescue => e
  log "could not set site description: #{e.class}: #{e.message}"
end

# ---------------------------------------------------------------------------
# 2. Welcome post from the owner.
# ---------------------------------------------------------------------------
#
# Only post if the owner has no statuses yet, so a re-run (should the
# marker ever be lost) doesn't spam duplicates.
begin
  if owner.statuses.where(reblog_of_id: nil).none?
    PostStatusService.new.call(
      owner,
      text: <<~POST.strip,
        Welcome to your very own Mastodon instance! 🐘

        This server is hosted on OpenHost and federates with the wider
        fediverse. You've been signed in automatically as the owner.

        A few starter accounts are already followed for you, so your
        Home timeline will start filling up as their posts federate in.
        Follow more people, post your first toot, and make it yours.
      POST
      visibility: 'public',
      language: 'en'
    )
    log 'posted welcome status'
  else
    log 'owner already has statuses; skipping welcome post'
  end
rescue => e
  log "could not post welcome status: #{e.class}: #{e.message}"
end

# ---------------------------------------------------------------------------
# 3. Follow a few well-known fediverse accounts so Home isn't empty.
# ---------------------------------------------------------------------------
#
# These are stable, high-signal, official-ish accounts. Resolving them
# does a live WebFinger + ActivityPub fetch against the remote server,
# so it can fail transiently at boot — each is wrapped independently.
# The owner can unfollow any of them from the normal UI.
SEED_FOLLOWS = %w[
  Mastodon@mastodon.social
  fediverse@mastodon.social
  feditips@mstdn.social
].freeze

SEED_FOLLOWS.each do |handle|
  begin
    target = ResolveAccountService.new.call(handle)
    if target.nil?
      log "could not resolve #{handle} (remote unreachable?); skipping"
      next
    end

    if owner.following?(target)
      log "already following #{handle}; skipping"
      next
    end

    FollowService.new.call(owner, target)
    log "followed #{handle}"
  rescue => e
    log "could not follow #{handle}: #{e.class}: #{e.message}"
  end
end

log 'seeding complete'
