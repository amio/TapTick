import { cp, mkdir, readFile, rm, writeFile } from "node:fs/promises";

const headers = { Accept: "application/vnd.github+json" };
if (process.env.GH_TOKEN) headers.Authorization = `Bearer ${process.env.GH_TOKEN}`;
const response = await fetch("https://api.github.com/repos/amio/TapTick/releases/latest", {
  headers,
  signal: AbortSignal.timeout(30_000),
});
if (!response.ok) throw new Error(`Release lookup failed: HTTP ${response.status}`);
const release = await response.json();
const asset = release.assets?.find(({ name }) =>
  name.startsWith("TapTick-") && name.endsWith(".dmg")
);
if (!asset || !/^v\d+\.\d+\.\d+(\+b\d+)?$/.test(release.tag_name)) {
  throw new Error("Latest release does not contain the expected TapTick DMG/version");
}
const url = new URL(asset.browser_download_url);
if (url.origin !== "https://github.com" ||
    !url.pathname.startsWith("/amio/TapTick/releases/download/")) {
  throw new Error("Unexpected release download URL");
}
const escapeHTML = (value) => value.replace(/[&<>"']/g, (character) => ({
  "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
})[character]);
let html = await readFile("public/index.html", "utf8");
const downloadMarker = "{{DOWNLOAD_URL}}";
const versionMarker = "{{VERSION}}";
if (html.split(downloadMarker).length !== 4 || html.split(versionMarker).length !== 2) {
  throw new Error("Landing page release placeholders changed; update the site builder");
}
html = html.replaceAll(downloadMarker, escapeHTML(url.href))
  .replaceAll(versionMarker, escapeHTML(release.tag_name.slice(1)));
await mkdir("build", { recursive: true });
await rm("build/site", { recursive: true, force: true });
await cp("public", "build/site", { recursive: true });
await writeFile("build/site/index.html", html);
console.log(`Built build/site for ${release.tag_name}: ${url.href}`);
