import os from 'node:os'

const PLATFORMS = {
  linux: 'linux',
  darwin: 'darwin',
  win32: 'windows'
}

const ARCHITECTURES = {
  x64: 'amd64',
  arm64: 'arm64'
}

/**
 * Maps the current runner to the release asset naming used by tronador-cli.
 */
export function resolvePlatform (nodePlatform = os.platform(), nodeArch = os.arch()) {
  const platform = PLATFORMS[nodePlatform]
  if (!platform) {
    throw new Error(`Unsupported operating system: ${nodePlatform}. This action supports Linux, macOS, and Windows.`)
  }

  const architecture = ARCHITECTURES[nodeArch]
  if (!architecture) {
    throw new Error(`Unsupported architecture: ${nodeArch}. This action supports amd64 and arm64.`)
  }

  return {
    platform,
    architecture,
    binaryName: platform === 'windows' ? 'tronador.exe' : 'tronador'
  }
}
