/**
 * Exports the Imagegen branding master as the website logo, favicons, home screen icon and
 * link preview image. Uses the site's Inter font and ../assets/branding/mobdev.png so every
 * surface shares the same artwork. macOS only (sips resizes the PNG exports).
 *
 *   bun run og-image                      # CHROME=/path/to/chrome to use another Chrome
 */
import { execFileSync } from "node:child_process";
import { copyFileSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const root = fileURLToPath(new URL("..", import.meta.url));
const chrome = process.env.CHROME ?? "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";

// The same variable Inter file the site loads (latin subset, weight and optical size axes). Inlined,
// because Chrome does not load fonts from file:// URLs.
const inter = readFileSync(join(root, "node_modules/@fontsource-variable/inter/files/inter-latin-opsz-normal.woff2"));
const fontFace = `@font-face {
  font-family: "Inter Variable";
  font-weight: 100 900;
  src: url(data:font/woff2;base64,${inter.toString("base64")}) format("woff2");
}`;

const master = join(root, "../assets/branding/mobdev.png");
for (const [name, size] of [["logo.png", 128], ["app-icon.png", 512], ["favicon.png", 32]] as const) {
  execFileSync("sips", ["-z", String(size), String(size), master, "--out", join(root, "public", name)], {
    stdio: "ignore",
  });
}
const logoData = readFileSync(join(root, "public/app-icon.png")).toString("base64");
const logo = `<img src="data:image/png;base64,${logoData}" alt="" />`;
// Preserve the existing SVG URL, embedding the generated artwork rather than redrawing it.
const faviconData = readFileSync(join(root, "public/logo.png")).toString("base64");
writeFileSync(join(root, "public/favicon.svg"),
  `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 128 128"><image width="128" height="128" href="data:image/png;base64,${faviconData}"/></svg>\n`);

function page(style: string, body: string): string {
  return `<!doctype html><html><head><meta charset="utf-8"><style>${fontFace}
html, body { margin: 0; overflow: hidden; }
${style}</style></head><body>${body}</body></html>`;
}

/** Screenshots `html` at width × height CSS pixels into `out`. Chrome needs windows at least ~500 px wide. */
function render(html: string, out: string, width: number, height: number): void {
  const dir = mkdtempSync(join(tmpdir(), "mobdev-og-"));
  try {
    const file = join(dir, "page.html");
    const screenshot = join(dir, "render.png");
    writeFileSync(file, html);
    try {
      execFileSync(
        chrome,
        [
          "--headless=new",
          `--user-data-dir=${join(dir, "chrome-profile")}`,
          "--no-first-run",
          "--disable-background-networking",
          "--hide-scrollbars",
          "--force-device-scale-factor=1",
          `--window-size=${width},${height}`,
          `--screenshot=${screenshot}`,
          pathToFileURL(file).href,
        ],
        { stdio: "ignore", timeout: 30_000, killSignal: "SIGTERM" },
      );
    } catch (error) {
      // Some Chrome versions keep background processes alive after writing the screenshot.
      // Accept only a fresh render from this invocation; all other failures still propagate.
      if (!(error instanceof Error && "code" in error && error.code === "ETIMEDOUT" && existsSync(screenshot))) {
        throw error;
      }
    }
    copyFileSync(screenshot, out);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
  const size = execFileSync("sips", ["-g", "pixelWidth", "-g", "pixelHeight", out], { encoding: "utf8" });
  if (!size.includes(`pixelWidth: ${width}`) || !size.includes(`pixelHeight: ${height}`)) {
    throw new Error(`${out} is not ${width}×${height}:\n${size}`);
  }
}

// The Open Graph image: the hero of the home page.
const og = join(root, "public/og.png");
render(
  page(
    `body {
  width: 1200px; height: 630px; box-sizing: border-box; padding-bottom: 8px;
  display: flex; flex-direction: column; align-items: center; justify-content: center; text-align: center;
  background: #fff; color: #1d1d1f;
  font-family: "Inter Variable"; font-optical-sizing: auto; -webkit-font-smoothing: antialiased;
}
.brand { display: flex; align-items: center; gap: 16px; font-size: 40px; font-weight: 600; letter-spacing: -0.02em; }
.brand img { width: 64px; height: 64px; }
h1 { margin: 40px 0 0; font-size: 100px; font-weight: 650; letter-spacing: -0.028em; line-height: 1.05; }
p { margin: 36px 0 0; font-size: 34px; letter-spacing: -0.01em; color: #6e6e73; }
p b { font-weight: 600; color: #1d1d1f; }`,
    `<div class="brand">${logo}Mobdev</div>
<h1>Mobile development.<br>All in one app.</h1>
<p>iPhone, Simulator and Android. Free and open source. <b>mobdev.sh</b></p>`,
  ),
  og,
  1200,
  630,
);

// iOS supplies its own corner mask. Composite the transparent master on its pale tile color so
// the corners stay light. Render at 3× because Chrome cannot make a 180 px window.
const icon = join(root, "public/apple-touch-icon.png");
render(page(`body { width: 540px; height: 540px; background: #f5f7fb; } img { display: block; width: 540px; height: 540px; }`, logo), icon, 540, 540);
execFileSync("sips", ["-z", "180", "180", icon], { stdio: "ignore" });

console.log(`Wrote website logo, PNG/SVG favicons, ${og} and ${icon}`);
