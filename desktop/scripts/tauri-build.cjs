const { spawnSync } = require("node:child_process");
const { join } = require("node:path");

function run(bin, args) {
  const command = process.platform === "win32" ? `${bin}.cmd` : bin;
  const commandPath = join(process.cwd(), "node_modules", ".bin", command);
  const result = process.platform === "win32"
    ? spawnSync(`"${commandPath}" ${args.join(" ")}`.trim(), {
        stdio: "inherit",
        shell: true,
      })
    : spawnSync(commandPath, args, {
        stdio: "inherit",
        shell: false,
      });

  if (result.error) {
    throw result.error;
  }
  if (typeof result.status === "number" && result.status !== 0) {
    process.exit(result.status);
  }
}

run("tsc", []);
run("vite", ["build"]);