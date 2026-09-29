/**
 * Renders the link preview image (public/og.png, 1200×630) and the home screen icon
 * (public/apple-touch-icon.png, 180×180) with headless Chrome. Uses the site's Inter font and the
 * logo from public/favicon.svg, so both stay in step with the site. macOS only (sips resizes the icon).
 *
 *   bun run og-image                      # CHROME=/path/to/chrome to use another Chrome
 */
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
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

const logo = readFileSync(join(root, "public/favicon.svg"), "utf8");

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
    writeFileSync(file, html);
    execFileSync(
      chrome,
      [
        "--headless=new",
        "--hide-scrollbars",
        "--force-device-scale-factor=1",
        `--window-size=${width},${height}`,
        `--screenshot=${out}`,
        pathToFileURL(file).href,
      ],
      { stdio: "ignore" },
    );
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
.brand svg { width: 64px; height: 64px; }
h1 { margin: 40px 0 0; font-size: 100px; font-weight: 650; letter-spacing: -0.028em; line-height: 1.05; }
p { margin: 36px 0 0; font-size: 34px; letter-spacing: -0.01em; color: #6e6e73; }
p b { font-weight: 600; color: #1d1d1f; }`,
    `<div class="brand">${logo}Mobdev</div>
<h1>Your agent.<br>A real iPhone.</h1>
<p>Free and open source. <b>mobdev.sh</b></p>`,
  ),
  og,
  1200,
  630,
);

// The home screen icon: iOS rounds the corners itself and shows transparency as black, so the logo
// fills the square. Rendered at 3× and scaled down, because Chrome cannot make a 180 px window.
const square = logo.replace(/<rect width="64" height="64" rx="15"/, '<rect width="64" height="64"');
if (square === logo) throw new Error("public/favicon.svg changed; update the background rect match");
const icon = join(root, "public/apple-touch-icon.png");
render(page(`body { width: 540px; height: 540px; } svg { display: block; width: 540px; height: 540px; }`, square), icon, 540, 540);
execFileSync("sips", ["-z", "180", "180", icon], { stdio: "ignore" });

console.log(`Wrote ${og} and ${icon}`);
