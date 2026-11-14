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
copyFileSync("../shared/scene3d/viewer.html", "dist/scene3d.html");
copyFileSync("../shared/scene3d/viewer.css", "dist/viewer.css");
copyFileSync("../shared/scene3d/brain-data.js", "dist/brain-data.js");
copyFileSync("node_modules/pdfjs-dist/build/pdf.worker.min.mjs", "dist/pdf.worker.min.mjs");
cpSync("public", "dist", { recursive: true });
// The iPad uses this same offline viewer inside WKWebView. Commit the small, minified
// resource bundle so opening the Xcode project does not require Node or a network.
const native3D = "../ipad/Halo/Resources/Scene3D";
mkdirSync(native3D, { recursive: true });
copyFileSync("../shared/scene3d/viewer.html", `${native3D}/viewer.html`);
copyFileSync("../shared/scene3d/viewer.css", `${native3D}/viewer.css`);
// The brain's geometry (built once by shared/scene3d/tools/build_brain.py) and the part names the app shows natively.
copyFileSync("../shared/scene3d/brain-data.js", `${native3D}/brain-data.js`);
copyFileSync("../shared/scene3d/catalog.json", `${native3D}/catalog.json`);
for (const model of ["brain", "neuron", "animal-cell"]) copyFileSync(`../shared/scene3d/thumb-${model}.png`, `${native3D}/thumb-${model}.png`);
copyFileSync("node_modules/three/LICENSE", `${native3D}/THREE-LICENSE.txt`);
copyFileSync("node_modules/three/LICENSE", "dist/THREE-LICENSE.txt");

const common = { bundle: true, sourcemap: watch ? "inline" : false, target: "chrome116", logLevel: "info", minify: false };
const builds = [
  { entryPoints: ["src/scene3d/viewer.ts"], outfile: "dist/viewer.js", format: "iife" },
  { entryPoints: ["src/background.ts"], outfile: "dist/background.js", format: "esm" },
  { entryPoints: ["src/content/index.ts"], outfile: "dist/content.js", format: "iife" },
  { entryPoints: ["src/sidepanel/main.ts"], outfile: "dist/sidepanel.js", format: "iife" },
  { entryPoints: ["src/setup/setup.ts"], outfile: "dist/setup.js", format: "iife" },
  { entryPoints: ["src/pdf/pdf.ts"], outfile: "dist/pdf.js", format: "esm" },
].map((b) => ({ ...common, ...b }));
builds.push({ ...common, entryPoints: ["src/scene3d/viewer.ts"], outfile: `${native3D}/viewer.js`, format: "iife", minify: true, sourcemap: false });

if (watch) {
  const ctxs = await Promise.all(builds.map((b) => esbuild.context(b)));
  await Promise.all(ctxs.map((c) => c.watch()));
  console.log("watching…");
} else {
  await Promise.all(builds.map((b) => esbuild.build(b)));
  console.log("built → extension/dist");
}
