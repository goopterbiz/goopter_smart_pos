const { execFileSync } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");

const { publish } = require("../electron-builder.cjs");

const root = path.join(__dirname, "..");

const git = (...args) => execFileSync("git", args, { cwd: root, encoding: "utf8" }).trim();
const fail = (message) => {
  console.error(`tag-release: ${message}`);
  process.exit(1);
};

const { version } = JSON.parse(fs.readFileSync(path.join(root, "package.json"), "utf8"));
const tag = `${publish[0].tagNamePrefix}${version}`;
const head = git("rev-parse", "HEAD");

if (git("status", "--porcelain", "--untracked-files=no") !== "") {
  fail("commit or stash changes first, so the tag matches what is built");
}

let tagged = "";
try {
  tagged = git("rev-parse", "--verify", "--quiet", `refs/tags/${tag}^{commit}`);
} catch {}
if (tagged === "") git("tag", "--no-sign", tag);
else if (tagged !== head) fail(`${tag} already points at ${tagged}, not HEAD ${head}. Bump the version.`);

for (const { owner, repo } of publish) {
  const url = `https://github.com/${owner}/${repo}.git`;
  console.log(`tag-release: pushing ${tag} to ${url}`);
  try {
    execFileSync("git", ["push", url, `refs/tags/${tag}`], { cwd: root, stdio: "inherit" });
  } catch {
    fail(`could not push ${tag} to ${url}`);
  }
}
