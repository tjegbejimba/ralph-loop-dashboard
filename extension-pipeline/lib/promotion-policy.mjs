import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";

const installedModuleUrl = new URL(
  "../../ralph-dashboard/lib/lane-promotion.mjs",
  import.meta.url,
);
const sourceModuleUrl = new URL(
  "../../extension/lib/lane-promotion.mjs",
  import.meta.url,
);
const lanePromotionUrl = existsSync(fileURLToPath(installedModuleUrl))
  ? installedModuleUrl
  : sourceModuleUrl;

export const { promoteOneTapReadiness } = await import(lanePromotionUrl);
