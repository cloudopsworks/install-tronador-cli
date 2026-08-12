import * as core from '@actions/core'
import { HttpClient } from '@actions/http-client'

import { RequestError, isRateLimited, withRetry } from './retry.mjs'

const USER_AGENT = 'cloudopsworks/install-tronador-cli'
const VERSION_PATTERN = /^[0-9A-Za-z._-]+$/

function client (options = {}) {
  return new HttpClient(USER_AGENT, [], options)
}

function apiHeaders (token) {
  const headers = {
    accept: 'application/vnd.github+json',
    'x-github-api-version': '2022-11-28'
  }
  if (token) {
    headers.authorization = `Bearer ${token}`
  }
  return headers
}

async function read (response) {
  const body = await response.readBody()
  const statusCode = response.message.statusCode
  if (statusCode !== undefined && statusCode >= 400) {
    throw new RequestError(`HTTP ${statusCode}`, {
      statusCode,
      headers: response.message.headers,
      body
    })
  }
  return body
}

/**
 * Resolves the latest tag through the REST API. Authenticated requests get
 * 5,000 per hour; anonymous ones share 60 per hour with every other job running
 * from the same runner IP, which is the usual source of 403s.
 */
export async function resolveViaApi ({ repository, token, apiBaseUrl, retryOptions }) {
  const url = `${apiBaseUrl}/repos/${repository}/releases/latest`
  const body = await withRetry(
    'Resolving the latest release through the GitHub API',
    async () => read(await client().get(url, apiHeaders(token))),
    retryOptions
  )

  const tag = JSON.parse(body).tag_name
  if (typeof tag !== 'string' || tag === '') {
    throw new Error('The GitHub API response did not contain a release tag')
  }
  return tag
}

/**
 * Resolves the latest tag from the /releases/latest redirect. This costs no
 * REST API quota at all, so it keeps working once the API budget is spent.
 */
export async function resolveViaRedirect ({ repository, serverBaseUrl, retryOptions }) {
  const url = `${serverBaseUrl}/${repository}/releases/latest`
  const location = await withRetry(
    'Resolving the latest release through the release redirect',
    async () => {
      const response = await client({ allowRedirects: false }).get(url, { accept: 'text/html' })
      const statusCode = response.message.statusCode
      const redirect = response.message.headers.location
      await response.readBody()

      if (statusCode !== undefined && statusCode >= 400) {
        throw new RequestError(`HTTP ${statusCode}`, { statusCode, headers: response.message.headers })
      }
      if (typeof redirect !== 'string' || redirect === '') {
        throw new RequestError(`${url} did not redirect to a release`, { statusCode })
      }
      return redirect
    },
    retryOptions
  )

  const tag = new URL(location, serverBaseUrl).pathname.split('/releases/tag/')[1]
  if (!tag) {
    throw new Error(`Unable to read a release tag from the redirect target ${location}`)
  }
  return decodeURIComponent(tag)
}

async function resolveLatestTag (options) {
  // Each strategy covers the other: a spent API budget falls through to the
  // redirect, and a blocked redirect falls through to the API. The cheaper of
  // the two for this caller goes first.
  const strategies = options.token
    ? [resolveViaApi, resolveViaRedirect]
    : [resolveViaRedirect, resolveViaApi]

  let lastError
  for (const strategy of strategies) {
    try {
      return await strategy(options)
    } catch (error) {
      lastError = error
      core.warning(`Unable to resolve the latest Tronador release (${error.message}).`)
    }
  }

  if (isRateLimited(lastError) && !options.token) {
    throw new Error(
      'Unable to resolve the latest Tronador release: GitHub rate limited this runner. ' +
      'Pass a token (with: token: ${{ github.token }}) or pin `version` to a release tag.'
    )
  }
  throw new Error(`Unable to resolve the latest Tronador release: ${lastError.message}`)
}

/**
 * Normalizes a requested version, or resolves `latest`, into a release tag.
 */
export async function resolveTag (options) {
  const requested = (options.version || 'latest').trim()
  if (requested === '' || requested === 'latest') {
    return resolveLatestTag(options)
  }

  if (!VERSION_PATTERN.test(requested)) {
    throw new Error(
      "Version must be 'latest' or a release tag containing only letters, numbers, dots, underscores, and hyphens"
    )
  }

  return requested.startsWith('v') ? requested : `v${requested}`
}
