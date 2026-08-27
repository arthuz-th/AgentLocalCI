import net from "node:net";

const proxyHost = process.argv[2];
const allowedProbeHost = process.argv[3];
const extraGateways = process.argv.slice(4);
if (!proxyHost || !/^[a-z0-9][a-z0-9_.-]+$/.test(proxyHost)) throw new Error("invalid proxy host");
if (!allowedProbeHost || !/^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])$/.test(allowedProbeHost)) throw new Error("invalid probe destination");

const directTargets = [...new Set([
  allowedProbeHost, "1.1.1.1", "8.8.8.8",
  "host.docker.internal", "gateway.docker.internal", "169.254.169.254",
  "10.0.0.1", "172.16.0.1", "192.168.0.1", "192.168.1.1", ...extraGateways,
])];
const directPorts = [80, 443, 2375, 2376];
function canConnect(host, port, timeoutMs = 800) {
  return new Promise((resolve) => {
    const socket = net.connect({ host, port });
    let settled = false;
    const finish = (value) => { if (settled) return; settled = true; socket.destroy(); resolve(value); };
    socket.once("connect", () => finish(true));
    socket.once("error", () => finish(false));
    socket.setTimeout(timeoutMs, () => finish(false));
  });
}
const results = await Promise.all(directTargets.flatMap((host) => directPorts.map(async (port) => ({ host, port, connected: await canConnect(host, port) }))));
const exposed = results.filter((item) => item.connected);
if (exposed.length) throw new Error(`forbidden direct endpoint reachable: ${exposed.map(({host, port}) => `${host}:${port}`).join(",")}`);

await new Promise((resolve, reject) => {
  const socket = net.connect({ host: proxyHost, port: 8080 });
  let response = "";
  const fail = (message) => { socket.destroy(); reject(new Error(message)); };
  socket.setTimeout(5000, () => fail("proxy probe timed out"));
  socket.once("error", (error) => fail(`proxy probe failed: ${error.code || "socket-error"}`));
  socket.once("connect", () => socket.write(`CONNECT ${allowedProbeHost}:443 HTTP/1.1\r\nHost: ${allowedProbeHost}:443\r\nConnection: close\r\n\r\n`));
  socket.on("data", (chunk) => {
    response += chunk.toString("ascii");
    if (response.includes("\r\n\r\n")) {
      if (!/^HTTP\/1\.[01] 200\b/.test(response)) return fail("allowlisted CONNECT was rejected");
      socket.destroy();
      resolve();
    }
    if (response.length > 1024) fail("proxy response exceeded bound");
  });
});
process.stdout.write("dependency network boundary probe passed\n");
