const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const { execFileSync } = require("node:child_process");
const POLICY_PATH = ".github/e2e-policy.json";
const policy = require("../e2e-policy.json");

function validatePolicy(p, cases) {
  if (
    p.schemaVersion !== 1 ||
    !Array.isArray(p.base) ||
    !p.base.length ||
    !p.groups ||
    !Array.isArray(p.rules)
  )
    throw Error("Invalid iOS E2E policy");
  const available = new Map(
    cases
      .filter(
        (c) => c.kind === "test" && c.platforms.ios.disposition === "required",
      )
      .map((c) => [c.id, c]),
  );
  for (const [name, ids] of Object.entries({ base: p.base, ...p.groups })) {
    if (!Array.isArray(ids) || !ids.length || new Set(ids).size !== ids.length)
      throw Error(`Invalid case group: ${name}`);
    for (const id of ids) {
      if (!available.has(id))
        throw Error(`Policy group ${name} requires unavailable case: ${id}`);
      if (
        name === "base" &&
        available.get(id).platforms.ios.backend !== "local"
      )
        throw Error(`Non-local base case: ${id}`);
    }
  }
  const names = new Set();
  for (const r of p.rules) {
    if (
      !r.name ||
      names.has(r.name) ||
      !Array.isArray(r.files) ||
      !Array.isArray(r.prefixes) ||
      !Array.isArray(r.groups)
    )
      throw Error("Invalid/duplicate policy rule");
    names.add(r.name);
    if (!r.files.length && !r.prefixes.length)
      throw Error(`Empty path rule: ${r.name}`);
    for (const f of [...r.files, ...r.prefixes]) {
      if (
        typeof f !== "string" ||
        !f ||
        f.startsWith("/") ||
        f.includes("..") ||
        f.includes("*") ||
        f.includes("\0")
      )
        throw Error(`Invalid policy path: ${f}`);
    }
    if (r.prefixes.some((f) => !f.endsWith("/")))
      throw Error(`Prefix must end with /: ${r.name}`);
    if (
      (r.full !== undefined && typeof r.full !== "boolean") ||
      (r.skip !== undefined && typeof r.skip !== "boolean")
    )
      throw Error(`Invalid policy action: ${r.name}`);
    if (r.skip && (r.full || r.groups.length))
      throw Error(`Skip rule selects tests: ${r.name}`);
    for (const g of r.groups)
      if (!p.groups[g]) throw Error(`Unknown case group: ${g}`);
  }
}

function matchingRules(p, file) {
  if (file.endsWith(".md"))
    return [{ name: "documentation", skip: true, groups: [] }];
  return p.rules.filter(
    (r) =>
      r.files.includes(file) ||
      r.prefixes.some((prefix) => file.startsWith(prefix)),
  );
}

function validateTree(p, files, cases) {
  validatePolicy(p, cases);
  const unknown = files.filter((f) => !matchingRules(p, f).length);
  const stale = p.rules.flatMap((r) => [
    ...r.files.filter((f) => !files.includes(f)),
    ...r.prefixes.filter((prefix) => !files.some((f) => f.startsWith(prefix))),
  ]);
  if (unknown.length || stale.length)
    throw Error(
      `Update ${POLICY_PATH} in this iOS PR.\nUnclassified paths: ${unknown.join(", ") || "none"}\nStale policy paths: ${[...new Set(stale)].join(", ") || "none"}`,
    );
}

function select(
  cases,
  {
    mode = "auto",
    files = [],
    shards = 1,
    release = false,
    pr = false,
    currentPolicy = policy,
    previousPolicy,
  } = {},
) {
  if (!["auto", "base", "full", "nightly"].includes(mode))
    throw Error("Invalid selection mode");
  if (![1, 2].includes(shards))
    throw Error("Only one or two shards are supported");
  if (
    !Array.isArray(files) ||
    files.some((f) => typeof f !== "string" || !f || f.includes("\0"))
  )
    throw Error("Invalid changed paths");
  validatePolicy(currentPolicy, cases);
  if (previousPolicy) validatePolicy(previousPolicy, cases);
  const policies = previousPolicy
    ? [currentPolicy, previousPolicy]
    : [currentPolicy];
  // Release pushes run the dedicated migration workflow. This workflow adds
  // migration only in a nightly run (or its explicit branch rehearsal).
  const includeMigration = !pr && mode === "nightly";
  const runnable = cases.filter(
    (c) =>
      c.kind === "test" &&
      c.platforms.ios.disposition === "required" &&
      (includeMigration || c.platforms.ios.pack !== "migration"),
  );
  const local = runnable.filter((c) => c.platforms.ios.backend === "local");
  const selected = new Set(currentPolicy.base);
  const reasons = [],
    coverageNotes = new Set();
  let full = mode === "full" || mode === "nightly";
  let code = mode !== "auto" || release;
  if (mode === "auto") {
    const unknown = [];
    for (const file of files) {
      let matched = false;
      for (const [index, p] of policies.entries()) {
        for (const rule of matchingRules(p, file)) {
          matched = true;
          reasons.push({
            file,
            rule: rule.name,
            policy: index ? "base" : "tested",
            action: rule.skip ? "skip" : rule.full ? "full" : "base+groups",
            groups: rule.groups,
          });
          if (rule.skip) continue;
          code = true;
          full ||= !!rule.full;
          for (const g of rule.groups)
            for (const id of p.groups[g]) selected.add(id);
          if (rule.coverageNote) coverageNotes.add(rule.coverageNote);
        }
      }
      if (!matched) unknown.push(file);
    }
    if (unknown.length)
      throw Error(
        `Unclassified changed paths: ${unknown.join(", ")}. Update ${POLICY_PATH} in the iOS PR; no paid jobs were selected.`,
      );
    // A policy edit cannot silently waive an existing base case for an app-code change.
    if (code && previousPolicy)
      for (const id of previousPolicy.base) selected.add(id);
  }
  if (full) for (const c of runnable) selected.add(c.id);
  const expected = code ? runnable.filter((c) => selected.has(c.id)) : [];
  const ids = expected
    .filter((c) => c.platforms.ios.backend === "local")
    .map((c) => c.id)
    .sort();
  const bins = Array.from({ length: shards }, () => []);
  for (const file of [
    ...new Set(local.filter((c) => ids.includes(c.id)).map((c) => c.file)),
  ].sort()) {
    const group = local
      .filter((c) => c.file === file && ids.includes(c.id))
      .map((c) => c.id);
    bins.sort((a, b) => a.length - b.length);
    bins[0].push(...group);
  }
  return {
    schemaVersion: 1,
    platform: "ios",
    mode,
    code,
    base: currentPolicy.base,
    ids,
    matrix: bins
      .filter((b) => b.length)
      .map((ids, i) => {
        // The hosted 42-case pack reached the widget cases at minute 90.
        const largePack = ids.length > 30;
        const attemptTimeoutMinutes = largePack ? 110 : ids.length > 5 ? 90 : 40;
        return {
          name: `local-${i + 1}`,
          ids: ids.sort(),
          attemptTimeoutMinutes,
          jobTimeoutMinutes: 3 * attemptTimeoutMinutes + 15,
          backendLifetime: largePack ? "6h" : ids.length > 5 ? "5h" : "4h",
        };
      }),
    staging: expected.some(
      (c) =>
        c.platforms.ios.backend === "regtest" &&
        c.platforms.ios.pack !== "migration",
    ),
    migration: expected.some((c) => c.platforms.ios.pack === "migration"),
    reasons,
    coverageNotes: [...coverageNotes],
    gaps: cases
      .filter((c) => c.platforms.ios.disposition === "gap")
      .map((c) => ({ id: c.id, ...c.platforms.ios })),
  };
}

function main() {
  const app = path.resolve(__dirname, "../..");
  const e2e = path.resolve(
    process.env.E2E_TEST_ROOT || path.join(app, "../bitkit-e2e-tests"),
  );
  const git = (...args) =>
    execFileSync("git", ["-C", app, ...args], { encoding: "utf8" }).trim();
  const inventory = JSON.parse(
    fs.readFileSync(path.join(e2e, "test/inventory.json"), "utf8"),
  );
  const tracked = execFileSync("git", ["-C", app, "ls-files", "-z"], {
    encoding: "utf8",
  })
    .split("\0")
    .filter(Boolean);
  validateTree(policy, tracked, inventory.cases);
  if (process.argv[2] === "check") {
    console.log(
      `iOS policy: all ${tracked.length} tracked paths classified; all case references valid`,
    );
    return;
  }
  const tested = git("rev-parse", "HEAD");
  const event = JSON.parse(
    fs.readFileSync(process.env.GITHUB_EVENT_PATH, "utf8"),
  );
  let pr = event.pull_request;
  const manualPr = process.env.E2E_MANUAL_PR;
  if (manualPr) {
    if (!/^\d+$/.test(manualPr)) throw Error("Invalid PR number");
    pr = JSON.parse(
      execFileSync(
        "gh",
        ["api", `repos/${process.env.GITHUB_REPOSITORY}/pulls/${manualPr}`],
        { encoding: "utf8" },
      ),
    );
  }
  const base = pr?.base?.sha;
  if (
    pr &&
    git("show", "-s", "--format=%P", "HEAD") !== `${base} ${pr.head.sha}`
  )
    throw Error("PR merge does not match current base and head");
  const files = base
    ? execFileSync(
        "git",
        ["-C", app, "diff", "--no-renames", "--name-only", "-z", base, tested],
        { encoding: "utf8" },
      )
        .split("\0")
        .filter(Boolean)
    : [];
  let previousPolicy;
  // Only the initial policy introduction has no base policy. A Git error must fail.
  if (base && git("ls-tree", base, "--", POLICY_PATH))
    previousPolicy = JSON.parse(git("show", `${base}:${POLICY_PATH}`));
  const mode =
    process.env.GITHUB_EVENT_NAME === "schedule"
      ? "nightly"
      : process.env.GITHUB_EVENT_NAME === "pull_request"
        ? "auto"
        : process.env.E2E_SELECTION || "full";
  if (mode === "auto" && !base)
    throw Error("Automatic manual selection requires a PR number");
  const result = select(inventory.cases, {
    mode,
    files,
    previousPolicy,
    pr: Boolean(pr),
    shards:
      process.env.GITHUB_EVENT_NAME === "workflow_dispatch"
        ? Number(process.env.E2E_SHARDS || 1)
        : 1,
    release:
      /^release-/.test(pr?.head?.ref || "") ||
      /^release-/.test(pr?.base?.ref || ""),
  });
  result.appSha = tested;
  result.e2eSha = execFileSync("git", ["-C", e2e, "rev-parse", "HEAD"], {
    encoding: "utf8",
  }).trim();
  result.policy = {
    path: POLICY_PATH,
    appSha: tested,
    sha256: crypto
      .createHash("sha256")
      .update(fs.readFileSync(path.join(app, POLICY_PATH)))
      .digest("hex"),
  };
  fs.writeFileSync("selection.json", JSON.stringify(result, null, 2) + "\n");
  if (process.env.GITHUB_OUTPUT)
    for (const key of [
      "code",
      "matrix",
      "staging",
      "migration",
      "appSha",
      "e2eSha",
    ])
      fs.appendFileSync(
        process.env.GITHUB_OUTPUT,
        `${key}=${typeof result[key] === "object" ? JSON.stringify(result[key]) : result[key]}\n`,
      );
  if (process.env.GITHUB_STEP_SUMMARY)
    fs.appendFileSync(
      process.env.GITHUB_STEP_SUMMARY,
      `## iOS E2E selection\n\nApp/policy: ${tested}; tests: ${result.e2eSha}\n\nLocal cases (${result.ids.length}): ${result.ids.join(", ") || "none"}\n\nStaging: ${result.staging}; migration: ${result.migration}; shards: ${result.matrix.length}\n\n${result.reasons.map((r) => `- ${r.file}: ${r.rule} (${r.policy})`).join("\n")}\n\nCoverage notes: ${result.coverageNotes.join("; ") || "none"}\n\nKnown gaps: ${result.gaps.map((g) => g.id).join(", ")}\n`,
    );
  console.log(JSON.stringify(result, null, 2));
}
if (require.main === module) {
  try {
    main();
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
module.exports = {
  policy,
  select,
  matchingRules,
  validatePolicy,
  validateTree,
};
