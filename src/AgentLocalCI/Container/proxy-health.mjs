import net from "node:net";

const socket = net.connect({ host: "127.0.0.1", port: 8080 });
const fail = () => process.exit(1);
socket.setTimeout(1500, fail);
socket.once("error", fail);
socket.once("connect", () => {
  socket.end();
  process.exit(0);
});
