import * as esbuild from "esbuild";
import { cpSync, mkdirSync, rmSync, copyFileSync } from "node:fs";

const watch = process.argv.includes("--watch");
rmSync("dist", { recursive: true, force: true });
mkdirSync("dist", { recursive: true });

// static files
copyFileSync("manifest.json", "dist/manifest.json");
copyFileSync("src/sidepanel/sidepanel.html", "dist/sidepanel.html");
copyFileSync("src/sidepanel/sidepanel.css", "dist/sidepanel.css");
copyFileSync("src/setup/setup.html", "dist/setup.html");
copyFileSync("src/pdf/pdf.html", "dist/pdf.html");
copyFileSync("node_modules/pdfjs-dist/build/pdf.worker.min.mjs", "dist/pdf.worker.min.mjs");
cpSync("public", "dist", { recursive: true });

const common = { bundle: true, sourcemap: watch ? "inline" : false, target: "chrome116", logLevel: "info", minify: false };
const builds = [
  { entryPoints: ["src/background.ts"], outfile: "dist/background.js", format: "esm" },
  { entryPoints: ["src/content/index.ts"], outfile: "dist/content.js", format: "iife" },
  { entryPoints: ["src/sidepanel/main.ts"], outfile: "dist/sidepanel.js", format: "iife" },
  { entryPoints: ["src/setup/setup.ts"], outfile: "dist/setup.js", format: "iife" },
  { entryPoints: ["src/pdf/pdf.ts"], outfile: "dist/pdf.js", format: "esm" },
].map((b) => ({ ...common, ...b }));

if (watch) {
  const ctxs = await Promise.all(builds.map((b) => esbuild.context(b)));
  await Promise.all(ctxs.map((c) => c.watch()));
  console.log("watching…");
} else {
  await Promise.all(builds.map((b) => esbuild.build(b)));
  console.log("built → extension/dist");
}
