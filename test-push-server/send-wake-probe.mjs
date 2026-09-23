import { readFileSync } from 'node:fs'
import { connect } from 'node:http2'
import { dirname, resolve } from 'node:path'
import { randomUUID, sign } from 'node:crypto'
import { fileURLToPath } from 'node:url'

const mode = process.argv[2] ?? 'wake'
const deviceToken = process.env.BITKIT_DEVICE_TOKEN?.trim()
const topic = process.env.BITKIT_APN_TOPIC ?? 'to.bitkit'
const keyId = process.env.APN_KEY_ID
const teamId = process.env.APN_TEAM_ID
const keyFile = process.env.APN_KEY_FILE

if (!['wake', 'alert', 'pair'].includes(mode)) {
  throw new Error('Usage: send-wake-probe.mjs [wake|alert|pair]')
}
if (!/^[0-9a-f]{64}$/i.test(deviceToken ?? '')) {
  throw new Error('Set BITKIT_DEVICE_TOKEN to the current development APNs device token')
}
if (!keyId || !teamId || !keyFile) {
  throw new Error('Set APN_KEY_ID, APN_TEAM_ID and APN_KEY_FILE')
}

const scriptDir = dirname(fileURLToPath(import.meta.url))
const privateKey = readFileSync(resolve(scriptDir, keyFile))
const encoded = value => Buffer.from(JSON.stringify(value)).toString('base64url')
const unsignedToken = `${encoded({ alg: 'ES256', kid: keyId })}.${encoded({ iss: teamId, iat: Math.floor(Date.now() / 1000) })}`
const signature = sign('sha256', Buffer.from(unsignedToken), { key: privateKey, dsaEncoding: 'ieee-p1363' }).toString('base64url')
const authorization = `bearer ${unsignedToken}.${signature}`
const host = process.env.APN_PRODUCTION === 'true' ? 'api.push.apple.com' : 'api.sandbox.push.apple.com'
const probeId = randomUUID()

async function send(pushType, payload) {
  const client = connect(`https://${host}`)
  try {
    const body = JSON.stringify(payload)
    const result = await new Promise((resolveResult, rejectResult) => {
      const request = client.request({
        ':method': 'POST',
        ':path': `/3/device/${deviceToken}`,
        'authorization': authorization,
        'apns-topic': topic,
        'apns-push-type': pushType,
        'apns-priority': pushType === 'background' ? '5' : '10',
        'apns-expiration': '0',
        'content-type': 'application/json',
      })
      let status
      let response = ''
      request.on('response', headers => { status = headers[':status'] })
      request.on('data', chunk => { response += chunk })
      request.on('end', () => resolveResult({ status, response }))
      request.on('error', rejectResult)
      request.end(body)
    })
    if (result.status !== 200) {
      throw new Error(`APNs rejected ${pushType} push: HTTP ${result.status} ${result.response}`)
    }
    console.log(`APNs accepted ${pushType} probe ${probeId}`)
  } finally {
    client.close()
  }
}

if (mode === 'wake' || mode === 'pair') {
  await send('background', { aps: { 'content-available': 1 }, bitkit_wake_probe: probeId })
}
if (mode === 'pair') {
  const delay = Number(process.env.WAKE_FALLBACK_DELAY_MS ?? 15000)
  if (!Number.isFinite(delay) || delay < 0 || delay > 60000) {
    throw new Error('WAKE_FALLBACK_DELAY_MS must be between 0 and 60000')
  }
  await new Promise(resolveDelay => setTimeout(resolveDelay, delay))
}
if (mode === 'alert' || mode === 'pair') {
  await send('alert', {
    aps: {
      alert: {
        title: 'Background Wake Fallback',
        body: 'Test only: the silent wake was sent before this alert.',
      },
    },
    bitkit_fallback_probe: probeId,
  })
}
