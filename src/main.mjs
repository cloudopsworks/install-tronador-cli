import * as core from '@actions/core'

import { install } from './installer.mjs'

async function run () {
  try {
    const token = core.getInput('token')
    if (token) {
      core.setSecret(token)
    }

    const result = await install({
      version: core.getInput('version'),
      installDir: core.getInput('install-dir'),
      token
    })

    core.setOutput('version', result.tag)
    core.setOutput('path', result.path)
    core.setOutput('cache-hit', String(result.cacheHit))
  } catch (error) {
    core.setFailed(error instanceof Error ? error.message : String(error))
  }
}

await run()
