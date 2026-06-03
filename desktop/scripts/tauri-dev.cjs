const { spawnSync } = require("node:child_process");
const { join } = require("node:path");

const command = process.platform === "win32" ? "vite.cmd" : "vite";
const commandPath = join(process.cwd(), "node_modules", ".bin", command);
const result = process.platform === "win32"
  ? spawnSync(`"${commandPath}"`, {
      stdio: "inherit",
      shell: true,
    })
  : spawnSync(commandPath, [], {
      stdio: "inherit",
      shell: false,
    });

if (result.error) {
  throw result.error;
}
if (typeof result.status === "number" && result.status !== 0) {
  process.exit(result.status);
}