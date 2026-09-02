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

function transactionId(request) {
  const rawTransaction = request.params?.[0]
  if (typeof rawTransaction !== "string" || rawTransaction.length === 0 || rawTransaction.length % 2 !== 0) {
    return "unknown"
  }

  const transaction = Buffer.from(rawTransaction, "hex")
  const firstHash = crypto.createHash("sha256").update(transaction).digest()
  return Buffer.from(crypto.createHash("sha256").update(firstHash).digest()).reverse().toString("hex")
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
