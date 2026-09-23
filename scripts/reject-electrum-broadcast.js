#!/usr/bin/env node

const crypto = require("node:crypto")
const net = require("node:net")

function option(name, fallback) {
  const index = process.argv.indexOf(`--${name}`)
  return index >= 0 ? process.argv[index + 1] : fallback
}

const listenHost = option("listen-host", "127.0.0.1")
const listenPort = Number(option("listen-port", "61001"))
const upstreamHost = option("upstream-host", "127.0.0.1")
const upstreamPort = Number(option("upstream-port", "60001"))
const rejectionMessage = option("message", "non-final")

function rejection(request) {
  return {
    jsonrpc: request.jsonrpc ?? "2.0",
    id: request.id,
    error: { code: -26, message: rejectionMessage },
  }
}

function doubleSha256(transaction) {
  const firstHash = crypto.createHash("sha256").update(transaction).digest()
  return Buffer.from(crypto.createHash("sha256").update(firstHash).digest()).reverse().toString("hex")
}

function compactSize(transaction, offset) {
  const prefix = transaction[offset]
  if (prefix === undefined) throw new Error("missing compact size")
  if (prefix < 0xfd) return { value: prefix, nextOffset: offset + 1 }

  const byteLength = prefix === 0xfd ? 2 : prefix === 0xfe ? 4 : 8
  const valueOffset = offset + 1
  const nextOffset = valueOffset + byteLength
  if (nextOffset > transaction.length) throw new Error("truncated compact size")

  const value =
    byteLength === 2
      ? BigInt(transaction.readUInt16LE(valueOffset))
      : byteLength === 4
        ? BigInt(transaction.readUInt32LE(valueOffset))
        : transaction.readBigUInt64LE(valueOffset)
  if (value > BigInt(Number.MAX_SAFE_INTEGER)) throw new Error("compact size is too large")

  return { value: Number(value), nextOffset }
}

function skip(transaction, offset, byteLength) {
  const nextOffset = offset + byteLength
  if (nextOffset > transaction.length) throw new Error("truncated transaction")
  return nextOffset
}

function transactionId(request) {
  const rawTransaction = request.params?.[0]
  if (typeof rawTransaction !== "string" || rawTransaction.length === 0 || rawTransaction.length % 2 !== 0) {
    return "unknown"
  }

  try {
    const transaction = Buffer.from(rawTransaction, "hex")
    if (transaction.length < 10 || transaction[4] !== 0 || transaction[5] === 0) return doubleSha256(transaction)

    let offset = 6
    const bodyOffset = offset
    const inputs = compactSize(transaction, offset)
    offset = inputs.nextOffset
    for (let input = 0; input < inputs.value; input += 1) {
      offset = skip(transaction, offset, 36)
      const script = compactSize(transaction, offset)
      offset = skip(transaction, script.nextOffset, script.value + 4)
    }

    const outputs = compactSize(transaction, offset)
    offset = outputs.nextOffset
    for (let output = 0; output < outputs.value; output += 1) {
      offset = skip(transaction, offset, 8)
      const script = compactSize(transaction, offset)
      offset = skip(transaction, script.nextOffset, script.value)
    }
    const outputsEndOffset = offset

    for (let input = 0; input < inputs.value; input += 1) {
      const items = compactSize(transaction, offset)
      offset = items.nextOffset
      for (let item = 0; item < items.value; item += 1) {
        const witness = compactSize(transaction, offset)
        offset = skip(transaction, witness.nextOffset, witness.value)
      }
    }

    if (offset + 4 !== transaction.length) throw new Error("unexpected transaction length")
    const transactionWithoutWitness = Buffer.concat([
      transaction.subarray(0, 4),
      transaction.subarray(bodyOffset, outputsEndOffset),
      transaction.subarray(offset),
    ])
    return doubleSha256(transactionWithoutWitness)
  } catch {
    return "unknown"
  }
}

function forwardClientLines(client, upstream) {
  let buffered = ""

  client.on("data", chunk => {
    buffered += chunk.toString("utf8")
    const lines = buffered.split("\n")
    buffered = lines.pop() ?? ""

    for (const line of lines) {
      if (line.length === 0) continue

      let request
      try {
        request = JSON.parse(line)
      } catch {
        upstream.write(`${line}\n`)
        continue
      }

      if (!Array.isArray(request) && request.method === "blockchain.transaction.broadcast") {
        process.stdout.write(`Rejected Electrum broadcast ${transactionId(request)}: ${rejectionMessage}\n`)
        client.write(`${JSON.stringify(rejection(request))}\n`)
      } else {
        upstream.write(`${line}\n`)
      }
    }
  })
}

const server = net.createServer(client => {
  const upstream = net.createConnection({ host: upstreamHost, port: upstreamPort })

  forwardClientLines(client, upstream)
  upstream.pipe(client)

  client.on("error", () => upstream.destroy())
  upstream.on("error", error => client.destroy(error))
  client.on("close", () => upstream.destroy())
  upstream.on("close", () => client.destroy())
})

server.listen(listenPort, listenHost, () => {
  process.stdout.write(
    `Electrum rejection proxy listening on ${listenHost}:${listenPort}, forwarding to ${upstreamHost}:${upstreamPort}\n`
  )
})

process.on("SIGINT", () => server.close())
process.on("SIGTERM", () => server.close())
