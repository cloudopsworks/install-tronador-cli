import * as core from '@actions/core'

// GitHub answers an exhausted rate limit with 403 (primary limit) or 429
// (secondary limit). 408 and 5xx are transient. Everything else is a real
// failure and is not worth retrying.
const RETRYABLE_STATUS_CODES = new Set([408, 429, 500, 502, 503, 504])

// Waiting out a primary rate limit can take up to an hour, which is far longer
// than a job should stall. Beyond this bound the caller falls back to another
// strategy instead of sleeping.
export const MAX_DELAY_SECONDS = 60

export class RequestError extends Error {
  constructor (message, { statusCode, headers = {}, body = '', retryable } = {}) {
    super(message)
    this.name = 'RequestError'
    this.statusCode = statusCode
    this.headers = headers
    this.body = body
    // Overrides the status-code heuristics when the caller knows better.
    this.retryable = retryable
  }
}

function header (error, name) {
  const value = error?.headers?.[name]
  return Array.isArray(value) ? value[0] : value
}

/**
 * True when a response is GitHub telling us to slow down rather than telling us
 * the request itself was wrong (a private repository, a bad token, ...).
 */
export function isRateLimited (error) {
  if (!(error instanceof RequestError)) {
    return false
  }
  if (error.statusCode === 429) {
    return true
  }
  if (error.statusCode !== 403) {
    return false
  }
  if (header(error, 'x-ratelimit-remaining') === '0') {
    return true
  }
  if (header(error, 'retry-after') !== undefined) {
    return true
  }
  return /rate limit|abuse detection|secondary rate/i.test(error.body || error.message || '')
}

export function isRetryable (error) {
  if (!(error instanceof RequestError)) {
    // Socket resets, DNS hiccups and TLS errors are all worth another attempt.
    return true
  }
  if (error.retryable !== undefined) {
    return error.retryable
  }
  if (error.statusCode === undefined) {
    return true
  }
  return RETRYABLE_STATUS_CODES.has(error.statusCode) || isRateLimited(error)
}

/**
 * Seconds to wait before the next attempt, preferring what GitHub tells us over
 * a blind backoff. Returns `undefined` when the wait would exceed
 * MAX_DELAY_SECONDS, meaning the caller should give up on this strategy.
 */
export function delaySeconds (error, attempt) {
  const retryAfter = Number(header(error, 'retry-after'))
  if (Number.isFinite(retryAfter) && retryAfter > 0) {
    return retryAfter <= MAX_DELAY_SECONDS ? retryAfter : undefined
  }

  if (header(error, 'x-ratelimit-remaining') === '0') {
    const reset = Number(header(error, 'x-ratelimit-reset'))
    if (Number.isFinite(reset)) {
      const wait = Math.ceil(reset - Date.now() / 1000) + 1
      if (wait > MAX_DELAY_SECONDS) {
        return undefined
      }
      return Math.max(wait, 1)
    }
  }

  return Math.min(2 ** attempt, MAX_DELAY_SECONDS)
}

function sleep (seconds) {
  return new Promise(resolve => setTimeout(resolve, seconds * 1000))
}

/**
 * Runs `operation` until it succeeds, the error is not worth retrying, or the
 * attempts are exhausted.
 */
export async function withRetry (description, operation, { attempts = 4, wait = sleep } = {}) {
  let lastError
  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    try {
      return await operation(attempt)
    } catch (error) {
      lastError = error
      if (!isRetryable(error) || attempt === attempts) {
        throw error
      }

      const delay = delaySeconds(error, attempt)
      if (delay === undefined) {
        core.warning(
          `${description} is rate limited for longer than ${MAX_DELAY_SECONDS}s; not waiting it out.`
        )
        throw error
      }

      core.warning(`${description} failed (${error.message}). Retrying in ${delay}s.`)
      await wait(delay)
    }
  }
  throw lastError
}
