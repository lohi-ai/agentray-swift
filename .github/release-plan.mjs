import { execFileSync } from "node:child_process";
import { appendFileSync, readFileSync, existsSync } from "node:fs";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

const stable = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-((?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*))*))?$/;
export function compareVersions(left, right) {
  const parse = value => {
    if (typeof value !== 'string' || !stable.test(value)) throw new Error('Expected semver');
    const [core, pre] = value.split(/-(.*)/s);
    return {core:core.split('.').map(BigInt),pre:pre?.split('.')};
  };
  const a=parse(left), b=parse(right);
  for(let i=0;i<3;i++) if(a.core[i] !== b.core[i]) return a.core[i] > b.core[i] ? 1 : -1;
  if (!a.pre || !b.pre) return a.pre ? -1 : b.pre ? 1 : 0;
  for(let i=0;i<Math.max(a.pre.length,b.pre.length);i++) {
    const x=a.pre[i], y=b.pre[i];
    if(x === y) continue;
    if(x === undefined || y === undefined) return x === undefined ? -1 : 1;
    const xn=/^\d+$/.test(x), yn=/^\d+$/.test(y);
    if(xn !== yn) return xn ? -1 : 1;
    return (xn ? BigInt(x) > BigInt(y) : x > y) ? 1 : -1;
  }
  return 0;
}

// Pure policy: an ordinary main push never invents a version. A retry can
// resume an unpublished tag on the same source commit without moving the tag.
export function releasePlan({version, refType, refName, commit, tags, published = false}) {
  compareVersions(version, version);
  const tag = `${version}`;
  if (refType === "tag" && refName !== tag) throw new Error("Tag must match source version");
  if (refType !== "tag" && (refType !== "branch" || refName !== "main")) throw new Error("Release requires main or a version tag");
  const existing = tags.find(t => t.tag === tag);
  const newer = tags.some(t => t.tag.startsWith("") && stable.test(t.tag.slice("".length)) && compareVersions(t.tag.slice("".length), version) > 0);
  if (newer) throw new Error("Refusing a version older than an existing release tag");
  if (refType === "tag" && (!existing || existing.commit !== commit)) throw new Error("Tag does not resolve to the checked-out commit");
  if (refType === "branch" && existing && existing.commit !== commit)
    return {version, tag, commit, release: false, createTag: false};
  return {version, tag, commit, release: !published, createTag: !existing && !published};
}

export function sourceVersion() {
  const version = existsSync('VERSION') ? readFileSync("VERSION", "utf8").trim()
    : process.env.RELEASE_REF_TYPE === 'tag' ? process.env.RELEASE_REF_NAME : null;
  compareVersions(version, version);
  return version;
}

function main() {
  if (!process.env.GITHUB_OUTPUT) throw new Error("CI only; use the tests for a local dry run");
  const git = (...args) => execFileSync("git", args, {encoding: "utf8"}).trim();
  const commit = git("rev-parse", "HEAD");
  const remote = git("ls-remote", "--tags", "origin"); // network/auth errors must fail, never mint a replacement tag
  const refs = new Map(remote.split("\n").filter(Boolean).map(line => line.split(/\s+/).reverse()));
  const tags = [...refs].filter(([ref]) => /^refs\/tags\//.test(ref) && !ref.endsWith("^{}"))
    .map(([ref, sha]) => ({tag: ref.slice("refs/tags/".length), commit: refs.get(`${ref}^{}`) ?? sha}));
  const version = sourceVersion();
  const input = {version, refType: process.env.RELEASE_REF_TYPE, refName: process.env.RELEASE_REF_NAME, commit, tags};
  let plan = releasePlan(input);
  if (plan.release && !plan.createTag) {
    try {
      const release = JSON.parse(execFileSync("gh", ["api", `repos/${process.env.GITHUB_REPOSITORY}/releases/tags/${plan.tag}`], {encoding: "utf8", stdio: ["ignore", "pipe", "pipe"]}));
      plan = releasePlan({...input, published: release.draft === false});
    } catch (error) {
      if (!String(error.stderr).includes("HTTP 404")) throw new Error("Cannot inspect existing release; retry after fixing GitHub access");
    }
  }
  for (const [key, value] of Object.entries(plan)) appendFileSync(process.env.GITHUB_OUTPUT, `${key}=${value}\n`);
  console.log(`${plan.tag}: ${plan.release ? "release pending" : "already released / no version change"}`);
}
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  try { main(); } catch (error) { console.error(error.message); process.exitCode = 1; }
}
