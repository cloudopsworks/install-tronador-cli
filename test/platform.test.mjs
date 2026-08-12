import assert from 'node:assert/strict'
import { describe, it } from 'node:test'

import { resolvePlatform } from '../src/platform.mjs'

describe('resolvePlatform', () => {
  it('maps supported runners to release asset names', () => {
    assert.deepEqual(resolvePlatform('linux', 'x64'), {
      platform: 'linux',
      architecture: 'amd64',
      binaryName: 'tronador'
    })
    assert.deepEqual(resolvePlatform('darwin', 'arm64'), {
      platform: 'darwin',
      architecture: 'arm64',
      binaryName: 'tronador'
    })
    assert.deepEqual(resolvePlatform('win32', 'x64'), {
      platform: 'windows',
      architecture: 'amd64',
      binaryName: 'tronador.exe'
    })
  })

  it('rejects unsupported runners', () => {
    assert.throws(() => resolvePlatform('freebsd', 'x64'), /Unsupported operating system/)
    assert.throws(() => resolvePlatform('linux', 'ia32'), /Unsupported architecture/)
  })
})
