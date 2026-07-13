import { cp, mkdir, readFile, rm } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const packageJson = JSON.parse(await readFile(join(root, "package.json"), "utf8"));
const manifest = JSON.parse(await readFile(join(root, "plugin.json"), "utf8"));
if (manifest.version !== packageJson.version) {
  throw new Error(`plugin.json version ${manifest.version} does not match package.json ${packageJson.version}`);
}
const buildRoot = join(root, "build");
const packageRoot = join(buildRoot, "feishu-quick-actions");
const releaseRoot = join(root, "release");
const archive = join(releaseRoot, `feishu-quick-actions-${packageJson.version}.ahakeyplugin`);

await rm(buildRoot, { recursive: true, force: true });
await mkdir(join(packageRoot, "dist"), { recursive: true });
await mkdir(releaseRoot, { recursive: true });
await rm(archive, { force: true });
await cp(join(root, "plugin.json"), join(packageRoot, "plugin.json"));
await cp(join(root, "README.md"), join(packageRoot, "README.md"));
await cp(join(root, "dist/main.js"), join(packageRoot, "dist/main.js"));

const result = spawnSync(
  "/usr/bin/ditto",
  [
    "-c",
    "-k",
    "--keepParent",
    "--norsrc",
    "--noextattr",
    "--noqtn",
    "--noacl",
    packageRoot,
    archive,
  ],
  {
    stdio: "inherit",
    env: { ...process.env, COPYFILE_DISABLE: "1", DITTONORSRC: "1" },
  },
);
if (result.status !== 0) {
  throw new Error(`ditto failed with status ${result.status ?? "unknown"}`);
}
console.log(archive);
