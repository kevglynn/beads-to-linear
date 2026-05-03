# Spike: OAuth Token Acquisition Race Under Concurrent CI

**Bead:** btl-9fz
**Date:** 2026-05-02
**Status:** Complete (desk research; empirical validation pending credentials)

## Context

The CI worker uses a single OAuth app (`beads-sync-bot`) with
`client_credentials` grant to push beads to Linear. Security review F-06
flagged that concurrent CI runs could race on token acquisition, potentially
invalidating each other's tokens. This spike validates that concern.

## Executive Summary

**The race condition is real and confirmed by Linear's documentation.**
Linear allows only one active `client_credentials` token per OAuth app.
Requesting a new token invalidates the previous one. Concurrent CI runs that
both attempt token acquisition will cause one run's token to be silently
invalidated, producing 401 errors mid-sync.

The existing `OAuthTokenManager` design (mutex + single cached token) is
correct for a single-process CI worker. The CI workflow's `concurrency`
group already serializes runs, preventing the multi-process race. No changes
to PR-3 are required, but token acquisition must remain behind a mutex and
CI runs must remain serialized.

---

## 1. Concurrent Token Acquisition

### Finding: Linear enforces single active token per OAuth app

From [Linear's OAuth documentation](https://linear.app/developers/oauth-2-0-authentication):

> Every OAuth2 app can only have one active client credentials token at a
> time since it is an `app` token. If you request a new client credentials
> token while you still have an active one, **we will invalidate the
> currently active token** and return a new token with a 30-day validity.

This means:

| Scenario | Outcome |
|---|---|
| Request A completes, then Request B starts | Token A invalidated, Token B is sole valid token |
| Request A and B fire concurrently | Both get 200 OK with different tokens, but only the *last-written* token survives — the other is invalidated server-side |
| Two CI runs detect expired token simultaneously | Race: both call `/oauth/token`, both get a new token, one invalidates the other's |

### Implication

If two CI worker processes both hold tokens from the same OAuth app, **only
the most recently issued token is valid**. The other will receive 401 on its
next API call.

### Risk Assessment

**High risk if CI runs are concurrent.** A CI run that acquires a token
mid-sync would invalidate the token of any other in-flight run, causing
partial sync failures.

**Low risk with current architecture.** The GitHub Actions workflow uses
`concurrency: { group: linear-sync-${{ github.repository }}, cancel-in-progress: false }`,
which serializes CI runs. Only one run executes at a time, eliminating the
multi-process race.

## 2. Token Reuse Safety

### Finding: No multi-token coexistence

Unlike some OAuth providers (e.g., Auth0, Okta) that allow multiple valid
tokens per client, **Linear's `client_credentials` grant enforces exactly
one active token per app.** This is explicitly documented and is a property
of the `app` actor token model — the token represents the application
itself, not a user session.

Additional invalidation triggers documented by Linear:
- Requesting a new `client_credentials` token (invalidates the previous)
- Rotating the client secret (invalidates the current token)

### Implications for OAuthTokenManager

The mutex-based, single-cached-token design in PR-3 is **exactly correct**:

1. **Mutex prevents intra-process races.** If two goroutines detect a 401
   simultaneously, only one acquires a new token; the other waits and reuses
   the refreshed token. This is the double-checked locking pattern.

2. **Single cached token matches Linear's model.** Since Linear only allows
   one active token, caching exactly one token is architecturally aligned.
   There is no benefit to caching multiple tokens (they'd be invalid).

3. **Refresh-on-401 is the documented pattern.** Linear's docs explicitly
   say: "your server is expected to fetch a new token if it receives a 401
   error." The 30-day TTL with no refresh token means the client must
   re-authenticate from scratch on expiry.

### What would break

| Scenario | Broken? | Why |
|---|---|---|
| Single CI process, mutex-guarded refresh | No | Mutex serializes token acquisition within the process |
| Two CI runs with `cancel-in-progress: false` + queue | No | GitHub Actions concurrency group serializes runs |
| Two CI runs without concurrency group | **YES** | Second run's token acquisition invalidates first run's token |
| Per-repo workers (decision d16 scenario) sharing one OAuth app | **YES** | Each worker's token refresh invalidates others' tokens |
| Per-repo workers with separate OAuth apps | No | Each app has its own token lifecycle |

## 3. Rate Limit Identity

### Finding: Rate limits are per-app, not per-token

From PLAN.md §2.3 (validated in spike d15):

| Auth method | Request limit | Complexity limit |
|---|---|---|
| Personal API key | 2,500/hour | 3,000,000/hour |
| OAuth app (`actor=app`) | 5,000/hour | 2,000,000/hour |

Linear's rate limits use a **leaky bucket** algorithm scoped to the
authenticated entity. For OAuth apps, the entity is the app itself (not the
token). Since only one token is active at a time, the question of "per-token
quota" is moot — there is always exactly one token, and it has the app's
full quota.

### Multi-repo CI worker implications

If decision d16 leads to per-repo workers sharing a single OAuth app:
- All workers share the same 5,000 requests/hour and 2,000,000
  complexity/hour quota
- This is sufficient for the projected load (PLAN.md estimates < 1% of rate
  limits for 50 devs)
- But the **token invalidation problem** (§2) is the real blocker, not
  rate limits

If per-repo workers need isolation:
- Separate OAuth apps per repo would give each its own quota and token
  lifecycle
- This adds credential management overhead (one `client_id`/`client_secret`
  per repo)

## 4. Findings Summary

### Is concurrent acquisition safe?

**No.** Linear's `client_credentials` grant enforces single active token
per app. Concurrent acquisition causes mutual invalidation.

### Is the OAuthTokenManager sufficient?

**Yes, for the current architecture.** The mutex-based, single-token design
is correct. Combined with the CI workflow's `concurrency` group (which
serializes runs), there is no window for concurrent token acquisition.

### Changes needed to PR-3?

**None.** The current PR-3 design (as described in PLAN.md §6) already
includes:
- Mutex-guarded token acquisition in `OAuthTokenManager`
- Token caching with 30-day TTL
- Auto-refresh on 401

The design is sound. The spike confirms the mutex is not over-engineering —
it's a necessary guard against the invalidation behavior.

### Recommendations

1. **Keep the CI concurrency group.** The `concurrency: { group:
   linear-sync-${{ github.repository }}, cancel-in-progress: false }`
   setting in the GitHub Actions workflow is a critical safety net. It must
   not be removed or changed to `cancel-in-progress: true` (which would
   allow a new run to cancel a mid-sync run, leaving Linear in an
   inconsistent state).

2. **Document the single-token constraint.** Add a comment in PR-3's
   `oauth.go` noting that Linear enforces one active token per app, so the
   mutex is architecturally required (not just a performance optimization).

3. **If per-repo workers are adopted (d16 evolution):** Each repo must
   either share the serialized CI concurrency group OR use a separate OAuth
   app. Sharing one OAuth app across unserialized workers will cause token
   thrashing.

4. **Token refresh logging.** When the `OAuthTokenManager` acquires a new
   token, it should log the event (with token prefix, not the full token)
   for audit trail. If a 401 triggers refresh and the refresh itself fails,
   that's a critical alert — it likely means another process just
   invalidated the token.

5. **No retry loop on token acquisition.** If token acquisition returns an
   error, fail the sync run immediately. Retrying token acquisition against
   Linear's single-token model risks a thrashing loop if another process is
   also retrying.

---

## Test Script

A test script is available at `scripts/spikes/test-oauth-concurrency.sh`.
It requires `LINEAR_OAUTH_CLIENT_ID` and `LINEAR_OAUTH_CLIENT_SECRET`
environment variables. The script:

1. Fires 5 concurrent token requests and compares returned tokens
2. Validates all tokens with a `viewer` query to check for mutual
   invalidation
3. Inspects rate-limit response headers across tokens

### Expected results (based on documentation analysis)

Based on Linear's documented behavior, the expected empirical results are:

- **Test 1 (concurrent acquisition):** All 5 requests succeed with 200 OK.
  Tokens may be identical (if Linear deduplicates) or different (if each
  request generates a new token, invalidating the previous). The
  documentation suggests the latter.

- **Test 2 (token validity):** If tokens are different, only the
  last-issued token should be valid. Earlier tokens should receive 401 or
  GraphQL authentication errors on the `viewer` query.

- **Test 3 (rate limits):** Rate-limit headers should show the same
  remaining quota regardless of which token is used, confirming per-app (not
  per-token) quota.

### Validation status

**Requires manual validation with credentials.** The environment variables
`LINEAR_OAUTH_CLIENT_ID` and `LINEAR_OAUTH_CLIENT_SECRET` were not available
during this spike. The findings above are based on Linear's official
documentation and are high-confidence, but empirical confirmation is
recommended before PR-3 merges.

To run manually:

```bash
export LINEAR_OAUTH_CLIENT_ID="your-client-id"
export LINEAR_OAUTH_CLIENT_SECRET="your-client-secret"
bash scripts/spikes/test-oauth-concurrency.sh
```
