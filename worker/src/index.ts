import { Api } from "./api.js";
import { loadConfig } from "./config.js";
import { WorkerLoop } from "./worker.js";

const config = loadConfig();
const api = new Api(config);

new WorkerLoop(config, api).start().catch((e) => {
  console.error(`[worker] fatal: ${String(e)}`);
  process.exit(1);
});
