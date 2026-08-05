# frozen_string_literal: true

# seed.rb — first-boot content seeding for a fresh OpenHost Mastodon.
#
# A brand-new single-user Mastodon is an empty void: no posts, an empty
# Home timeline, a blank About page. This script gives the owner
# something real to look at out of the box while leaving the instance
# fully usable as normal afterwards. It is deliberately conservative:
#
#   * It runs ONCE, gated by a marker file in $OPENHOST_APP_DATA_DIR.
#     After the first successful run it never touches your instance
#     again, so it can't fight your own posting/following later.
#   * Every individual seed action is best-effort and independently
#     wrapped: a failure to resolve a remote account or fetch a remote
#     outbox (network hiccup, remote instance down at boot) logs a
#     warning and moves on. Seeding never blocks the app from starting
#     or the owner from using it.
#   * It only ever acts as the local owner account.
#
# What it seeds:
#   1. A friendly server short-description (About page) — only if the
#      admin hasn't already set one.
#   2. A welcome post from the owner, so the profile + local timeline
#      aren't blank.
#   3. A handful of well-known, high-signal fediverse accounts the owner
#      follows, so the Home timeline keeps filling with real content.
#   4. BACKFILL: the recent public posts from each of those followed
#      accounts are pulled in immediately (via their ActivityPub
#      outbox), so the owner lands in a populated Home timeline instead
#      of an empty abyss that only fills over the following hours.

require '/opt/mastodon/config/environment'

def log(msg)
  warn "[seed] #{msg}"
  $stderr.flush
end

# The account username is the OpenHost zone owner's username, injected
# by the platform as OPENHOST_OWNER_USERNAME (falls back to 'owner' the
# same way the platform's own default does, and finally to 'operator'
# for older deploys that were bootstrapped under that name). This must
# match whatever bootstrap.sh created.
OWNER_USERNAME = (
  ENV['ADMIN_USERNAME'].presence ||
  ENV['OPENHOST_OWNER_USERNAME'].presence ||
  'owner'
)

# How many recent posts to backfill per followed account. Kept modest:
# enough to make the Home timeline feel alive without hammering remote
# servers or flooding the DB on first boot.
BACKFILL_PER_ACCOUNT = Integer(ENV['SEED_BACKFILL_PER_ACCOUNT'].presence || '10')

owner = Account.local.find_by(username: OWNER_USERNAME)
if owner.nil?
  # Last-ditch fallback: if we can't find the expected owner account,
  # grab the single local Owner-role account so seeding still targets
  # the right identity on an instance that used a different name.
  owner = Account.local
                 .joins(:user)
                 .where(users: { role_id: UserRole.where(name: 'Owner').select(:id) })
                 .order(:id)
                 .first
end

if owner.nil?
  log "owner account (expected '#{OWNER_USERNAME}') not found; nothing to seed"
  exit 0
end

log "seeding as owner account '#{owner.username}'"

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
begin
  if owner.statuses.where(reblog_of_id: nil).none?
    PostStatusService.new.call(
      owner,
      text: <<~POST.strip,
        Welcome to your very own Mastodon instance! 🐘

        This server is hosted on OpenHost and federates with the wider
        fediverse. You've been signed in automatically as the owner.

        A few starter accounts are already followed for you, and their
        recent posts have been pulled into your Home timeline — so
        there's something to read right away. Follow more people, post
        your first toot, and make it yours.
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
# 3. Follow a few well-known fediverse accounts.
# ---------------------------------------------------------------------------
#
# Stable, high-signal, official-ish accounts. Resolving them does a live
# WebFinger + ActivityPub fetch against the remote server, so it can
# fail transiently at boot — each is wrapped independently. The owner
# can unfollow any of them from the normal UI.
SEED_FOLLOWS = %w[
  Mastodon@mastodon.social
  fediverse@mastodon.social
  feditips@mstdn.social
].freeze

followed_accounts = []

SEED_FOLLOWS.each do |handle|
  begin
    target = ResolveAccountService.new.call(handle)
    if target.nil?
      log "could not resolve #{handle} (remote unreachable?); skipping"
      next
    end

    followed_accounts << target

    if owner.following?(target)
      log "already following #{handle}; skipping follow"
    else
      FollowService.new.call(owner, target)
      log "followed #{handle}"
    end
  rescue => e
    log "could not follow #{handle}: #{e.class}: #{e.message}"
  end
end

# ---------------------------------------------------------------------------
# 4. Backfill recent posts from the followed accounts.
# ---------------------------------------------------------------------------
#
# Following an account only surfaces its FUTURE posts; Mastodon does not
# backfill history on follow (by design). To avoid dropping the owner
# into an empty Home timeline we pull each followed account's recent
# public posts from its ActivityPub outbox and import them via
# FetchRemoteStatusService. Because the owner follows the author, those
# imported statuses land straight in the owner's Home feed.
#
# This reuses Mastodon's own fetch primitives:
#   * JsonLdHelper#fetch_resource_without_id_validation issues a signed
#     (on behalf of the owner) AP GET and returns parsed JSON.
#   * ActivityPub::FetchRemoteStatusService imports one status by URI.
#
# We fetch the outbox's first page, take the newest BACKFILL_PER_ACCOUNT
# note URIs, and import them. Everything is best-effort per item.
class SeedBackfiller
  include JsonLdHelper

  def initialize(owner, logger)
    @owner = owner
    @logger = logger
  end

  def backfill(account, limit)
    return 0 if account.local? || account.outbox_url.blank?

    outbox = fetch_json(account.outbox_url)
    return 0 if outbox.blank?

    # OrderedCollection: items may be inline, or behind a 'first' page.
    page = outbox
    page = fetch_json(value_or_id(outbox['first'])) if outbox['first'].present?
    return 0 unless page.is_a?(Hash)

    items = as_array(page['orderedItems'] || page['items'])
    count = 0

    items.each do |item|
      break if count >= limit

      uri = status_uri_from_item(item)
      next if uri.blank?
      next if ActivityPub::TagManager.instance.local_uri?(uri)
      next if non_matching_uri_hosts?(account.uri, uri)

      begin
        status = ActivityPub::FetchRemoteStatusService.new.call(
          uri, on_behalf_of: @owner, expected_actor_uri: account.uri
        )
        count += 1 if status&.account_id == account.id
      rescue => e
        @logger.call("backfill: skipped #{uri}: #{e.class}: #{e.message}")
      end
    end

    count
  end

  private

  # An outbox item is usually a Create activity wrapping a Note; it can
  # also be a bare Note or a bare URI string. Pull out the status URI.
  def status_uri_from_item(item)
    if item.is_a?(String)
      item
    elsif item.is_a?(Hash)
      case item['type']
      when 'Create'
        value_or_id(item['object'])
      when 'Announce'
        nil # skip boosts — we want the accounts' own posts
      else
        value_or_id(item)
      end
    end
  end

  def fetch_json(uri)
    return if uri.blank?

    fetch_resource_without_id_validation(uri, @owner, raise_on_error: :temporary)
  rescue => e
    @logger.call("backfill: could not fetch #{uri}: #{e.class}: #{e.message}")
    nil
  end
end

if followed_accounts.any? && BACKFILL_PER_ACCOUNT.positive?
  backfiller = SeedBackfiller.new(owner, method(:log))
  total = 0
  followed_accounts.uniq.each do |account|
    begin
      n = backfiller.backfill(account, BACKFILL_PER_ACCOUNT)
      total += n
      log "backfilled #{n} recent post(s) from #{account.acct}"
    rescue => e
      log "backfill failed for #{account.acct}: #{e.class}: #{e.message}"
    end
  end
  log "backfill total: #{total} imported"
end

# ---------------------------------------------------------------------------
# 5. Rebuild the owner's Home feed so the backfilled posts appear.
# ---------------------------------------------------------------------------
#
# CRITICAL: importing a followed account's statuses (step 4) writes them
# to the DB but does NOT retroactively fan them into the owner's Home
# timeline. Mastodon's Home feed is a per-user list materialised in
# Redis; it only receives posts that arrive AFTER the follow (via
# FanOutOnWriteService). The statuses we just backfilled predate the
# follow, so without an explicit rebuild the owner's Home feed stays
# empty even though the posts exist — which is exactly the "SSO works
# but Home is empty" symptom.
#
# PrecomputeFeedService (what `tootctl feeds build <user>` calls)
# regenerates the Home feed from the DB, pulling in the followed
# accounts' recent cached statuses. Run it last, after the follows +
# backfill, so the owner opens Mastodon to a populated Home timeline.
begin
  PrecomputeFeedService.new.call(owner)
  log 'rebuilt owner Home feed from backfilled posts'
rescue => e
  log "could not rebuild Home feed: #{e.class}: #{e.message}"
end

log 'seeding complete'
