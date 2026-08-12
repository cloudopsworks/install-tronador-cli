import assert from 'node:assert/strict'
import { describe, it } from 'node:test'

import { MAX_DELAY_SECONDS, RequestError, delaySeconds, isRateLimited, isRetryable, withRetry } from '../src/retry.mjs'

function rateLimited (extraHeaders = {}) {
  return new RequestError('HTTP 403', {
    statusCode: 403,
    headers: { 'x-ratelimit-remaining': '0', ...extraHeaders },
    body: '{"message":"API rate limit exceeded for 20.1.2.3."}'
  })
}

describe('isRateLimited', () => {
  it('recognizes a primary rate limit', () => {
    assert.equal(isRateLimited(rateLimited()), true)
  })

  it('recognizes a secondary rate limit', () => {
    assert.equal(isRateLimited(new RequestError('HTTP 429', { statusCode: 429 })), true)
  })

  it('does not treat an ordinary 403 as a rate limit', () => {
    const forbidden = new RequestError('HTTP 403', {
      statusCode: 403,
      headers: { 'x-ratelimit-remaining': '4999' },
      body: '{"message":"Resource not accessible by integration"}'
    })
    assert.equal(isRateLimited(forbidden), false)
    assert.equal(isRetryable(forbidden), false)
  })
})

describe('delaySeconds', () => {
  it('honors retry-after', () => {
    assert.equal(delaySeconds(rateLimited({ 'retry-after': '12' }), 1), 12)
  })

  it('honors x-ratelimit-reset', () => {
    const reset = Math.floor(Date.now() / 1000) + 10
    const delay = delaySeconds(rateLimited({ 'x-ratelimit-reset': String(reset) }), 1)
    assert.ok(delay >= 10 && delay <= 12, `unexpected delay ${delay}`)
  })

  it('gives up rather than sleeping through a full rate limit window', () => {
    const reset = Math.floor(Date.now() / 1000) + 3600
    assert.equal(delaySeconds(rateLimited({ 'x-ratelimit-reset': String(reset) }), 1), undefined)
    assert.equal(delaySeconds(rateLimited({ 'retry-after': '3600' }), 1), undefined)
  })

  it('backs off exponentially without rate limit hints', () => {
    const error = new RequestError('HTTP 503', { statusCode: 503 })
    assert.equal(delaySeconds(error, 1), 2)
    assert.equal(delaySeconds(error, 3), 8)
    assert.equal(delaySeconds(error, 20), MAX_DELAY_SECONDS)
  })
})

describe('withRetry', () => {
  it('retries transient failures and returns the eventual result', async () => {
    let calls = 0
    const waits = []
    const result = await withRetry('test', async () => {
      calls += 1
      if (calls < 3) {
        throw new RequestError('HTTP 503', { statusCode: 503 })
      }
      return 'ok'
    }, { attempts: 4, wait: async seconds => waits.push(seconds) })

    assert.equal(result, 'ok')
    assert.equal(calls, 3)
    assert.deepEqual(waits, [2, 4])
  })

  it('does not retry a failure that will not fix itself', async () => {
    let calls = 0
    await assert.rejects(withRetry('test', async () => {
      calls += 1
      throw new RequestError('HTTP 404', { statusCode: 404 })
    }, { attempts: 4, wait: async () => {} }))

    assert.equal(calls, 1)
  })

  it('stops immediately when the rate limit window is longer than the cap', async () => {
    let calls = 0
    const reset = Math.floor(Date.now() / 1000) + 3600
    await assert.rejects(withRetry('test', async () => {
      calls += 1
      throw rateLimited({ 'x-ratelimit-reset': String(reset) })
    }, { attempts: 4, wait: async () => {} }))

    assert.equal(calls, 1)
  })
})
