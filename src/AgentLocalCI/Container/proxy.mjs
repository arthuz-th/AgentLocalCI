import dns from "node:dns/promises";
import http from "node:http";
import net from "node:net";

const allowedHosts = new Set(
  (process.env.AGENTLOCALCI_ALLOWED_HOSTS || "")
    .split(",")
    .map((host) => host.trim().toLowerCase())
    .filter(Boolean),
);
if (allowedHosts.size === 0) throw new Error("dependency proxy has no allowed hosts");
for (const host of allowedHosts) {
  if (!/^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])$/.test(host) || host.includes("..") || !host.includes(".")) {
    throw new Error("dependency proxy received an invalid host allowlist");
  }
}

function isForbiddenAddress(address) {
  if (net.isIPv4(address)) {
    const octets = address.split(".").map(Number);
    return (
      octets[0] === 0 || octets[0] === 10 || octets[0] === 100 && octets[1] >= 64 && octets[1] <= 127 ||
      octets[0] === 127 || octets[0] === 169 && octets[1] === 254 ||
      octets[0] === 172 && octets[1] >= 16 && octets[1] <= 31 ||
      octets[0] === 192 && octets[1] === 0 && octets[2] === 0 ||
      octets[0] === 192 && octets[1] === 168 || octets[0] === 198 && octets[1] >= 18 && octets[1] <= 19 ||
      octets[0] >= 224
    );
  }
  if (net.isIPv6(address)) {
    const normalized = address.toLowerCase();
    return (
      normalized === "::" || normalized === "::1" || normalized.startsWith("fc") || normalized.startsWith("fd") ||
      /^fe[89ab]/.test(normalized) || normalized.startsWith("ff") ||
      normalized.startsWith("::ffff:10.") || normalized.startsWith("::ffff:127.") ||
      normalized.startsWith("::ffff:169.254.") || normalized.startsWith("::ffff:172.") ||
      normalized.startsWith("::ffff:192.168.")
    );
  }
  return true;
}

async function resolvePublicAddress(host) {
  const addresses = await dns.resolve4(host);
  if (!addresses.length || addresses.some((address) => isForbiddenAddress(address))) {
    throw new Error("destination resolved to a forbidden or ambiguous IPv4 address");
  }
  return { address: addresses[0], family: 4 };
}

const server = http.createServer((_request, response) => {
  response.writeHead(403, { "content-type": "text/plain" });
  response.end("Only exact-allowlisted HTTPS CONNECT requests are supported.\n");
});
server.on("connect", async (request, clientSocket, head) => {
  const separator = request.url.lastIndexOf(":");
  const host = separator > 0 ? request.url.slice(0, separator).toLowerCase().replace(/\.$/, "") : "";
  const port = Number(separator > 0 ? request.url.slice(separator + 1) : "");
  if (!host || net.isIP(host) || port !== 443 || !allowedHosts.has(host)) {
    clientSocket.end("HTTP/1.1 403 Forbidden\r\n\r\n");
    return;
  }
  try {
    const target = await resolvePublicAddress(host);
    const upstream = net.connect({ host: target.address, port, family: target.family });
    upstream.setTimeout(120_000);
    clientSocket.setTimeout(120_000);
    upstream.once("connect", () => {
      clientSocket.write("HTTP/1.1 200 Connection Established\r\n\r\n");
      if (head.length) upstream.write(head);
      upstream.pipe(clientSocket);
      clientSocket.pipe(upstream);
    });
    upstream.on("error", () => clientSocket.destroy());
    upstream.on("timeout", () => upstream.destroy());
    clientSocket.on("error", () => upstream.destroy());
    clientSocket.on("timeout", () => clientSocket.destroy());
  } catch {
    clientSocket.end("HTTP/1.1 502 Bad Gateway\r\n\r\n");
  }
});
server.listen(8080, "0.0.0.0", () => process.stdout.write("AgentLocalCI dependency proxy ready.\n"));
