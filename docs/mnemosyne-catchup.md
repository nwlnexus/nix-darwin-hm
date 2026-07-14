# Mnemosyne backlog catch-up (per machine)

Durable, repeatable steps to catch a nix-managed dev machine up when it has a
large parked mnemosyne queue (`~/.claude/mnemosyne/queue`). Safe to run on any
host, any number of times.

## Background

Mnemosyne no longer extracts learnings locally (ollama is retired). The drain
now POSTs each session transcript to moneta's `POST /capture-session`, which
extracts + embeds + stores server-side and returns the learnings; the client
routes `decision`/`lesson` items to the second-brain inbox. A machine that ran
an older build (or was offline) accumulates un-drained transcripts in the queue.
This procedure flushes them.

**It is idempotent and resumable.** moneta dedupes each session via a receipt
(re-POST → `already_captured`, no re-extraction), the brain inbox dedupes via
the local ledger, and queue entries are removed only on success — so an
interrupted or repeated run just picks up where it left off. Permanent failures
(a transcript whose ephemeral temp dir was garbage-collected) move to
`~/.claude/mnemosyne/dead/` and auto-prune after 30 days.

## One-time prerequisites (per host)

The mnemosyne CLI is a **private** flake input (`github:nwlnexus/mnemosyne`) and
its closure is served from the nwlnexus R2 nix cache. If this host has never
been set up for those, run once (needs sudo; reads secrets from
`~/projects/personal/.env`):

```bash
just materialize-nix-github-token   # private flake fetch
just materialize-r2-cache-creds     # substitute the prebuilt closure
```

## Catch-up steps

Run these on the machine being caught up:

```bash
# 1. Get the latest config (includes the pinned mnemosyne build).
cd ~/projects/personal/nix-darwin-hm && git pull

# 2. Install that build.
sudo darwin-rebuild switch --flake .

# 3. Flush the parked queue through moneta (clears stale drains + the lock,
#    then drains with concurrency, then prints status).
just mnemosyne-catchup
```

Then watch it drain to zero:

```bash
just mnemosyne-status     # re-run; "queue" should trend to 0
```

### What to expect

- **`queue` decreasing** is the real progress signal.
- **`moneta total entries` climbs slowly** — most backlog transcripts overlap
  content already captured, so their learnings hit moneta's dedup
  (`duplicate_blocked`) rather than being stored again. This is correct.
- **New `decision`/`lesson` docs** appear in the second-brain inbox
  (`raw/_inbox`) as genuinely-new items are found.
- Tune throughput with `MNEMOSYNE_DRAIN_CONCURRENCY` (default 8), e.g.
  `MNEMOSYNE_DRAIN_CONCURRENCY=12 just mnemosyne-catchup`.

## Gotcha: stale drains from pre-rebuild sessions

Claude/agent sessions opened **before** the rebuild still carry the old
generation's `PATH`, so their SessionStart hooks keep launching the *old*
mnemosyne build, which can squat the drain lock and make a manual drain exit
with "another drain is active". `just mnemosyne-catchup` kills those stale
drains and clears the lock before starting, but the cleanest fix is to **close
and reopen** any sessions that predate the rebuild.

## Verifying the pipeline end to end

```bash
# capture (server-side extraction) — should return 200 with learnings
curl -sS -X POST "$MONETA_URL/capture-session" \
  -H "content-type: application/json" -H "authorization: Bearer $MONETA_AUTH_TOKEN" \
  -H "CF-Access-Client-Id: $CF_ACCESS_CLIENT_ID" -H "CF-Access-Client-Secret: $CF_ACCESS_CLIENT_SECRET" \
  --data '{"turns":[{"role":"assistant","text":"We decided X because Y."}],"session":"probe-'"$(date +%s)"'","cwd":"/tmp","ts":"'"$(date -u +%FT%TZ)"'","source":"probe"}'
```

`MONETA_URL` / `MONETA_AUTH_TOKEN` / `CF_ACCESS_CLIENT_*` come from
`~/projects/personal/.env` (op-secrets).
