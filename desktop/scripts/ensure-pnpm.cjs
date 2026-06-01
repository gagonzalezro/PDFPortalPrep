// Rechaza instalar con npm/yarn: este proyecto usa pnpm.
// Se ejecuta en `preinstall`. Offline, sin dependencias.
// pnpm 11 no fija npm_config_user_agent en los lifecycle scripts, así que
// detectamos pnpm por npm_execpath (.../pnpm) o por PNPM_SCRIPT_SRC_DIR.
const execpath = process.env.npm_execpath || "";
const isPnpm = /pnpm/i.test(execpath) || !!process.env.PNPM_SCRIPT_SRC_DIR;
if (!isPnpm) {
  console.error("\n✖ Este proyecto usa pnpm. Ejecuta `pnpm install` (no npm ni yarn).\n");
  process.exit(1);
}
