"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const { execFileSync } = require("node:child_process");
const path = require("node:path");
const {
  eligible,
  needsSmoke,
  verifyMerge,
  inspect,
  verdict,
} = require("./smoke-shadow.cjs");

const head = "a".repeat(40),
  base = "b".repeat(40),
  merge = "c".repeat(40);
function event(action = "synchronize") {
  return {
    action,
    pull_request: {
      number: 264,
      draft: false,
      head: { sha: head },
      base: { ref: "master" },
    },
  };
}

test("normal PR, ready-for-review, real retarget and dispatch are eligible", () => {
  for (const action of [
    "opened",
    "synchronize",
    "reopened",
    "ready_for_review",
  ])
    assert.equal(eligible("pull_request", event(action)), true);
  assert.equal(
    eligible("pull_request", {
      ...event("edited"),
      changes: { base: { ref: { from: "stack" } } },
    }),
    true,
  );
  assert.equal(eligible("workflow_dispatch", {}), true);
});
test("draft, stacked PR and unrelated edited event do not schedule smoke", () => {
  const draft = event();
  draft.pull_request.draft = true;
  const stacked = event();
  stacked.pull_request.base.ref = "feature";
  for (const payload of [draft, stacked, event("edited")])
    assert.equal(eligible("pull_request", payload), false);
});
test("path filtering preserves successful explicit no-code selection", () => {
  assert.equal(
    needsSmoke("pull_request", event(), ["README.md", "journeys/a.xml"]),
    false,
  );
  for (const file of [
    "Bitkit/Wallet.swift",
    "Bitkit.xcodeproj/project.pbxproj",
    ".github/workflows/e2e-smoke-shadow.yml",
    ".github/scripts/smoke-shadow.cjs",
  ])
    assert.equal(needsSmoke("pull_request", event(), [file]), true);
  assert.equal(needsSmoke("workflow_dispatch", {}, []), true);
});
test("head/base changes and malformed merge identity fail closed", () => {
  verifyMerge({ tested: merge, parents: [base, head], head, base });
  for (const parents of [
    [base, "d".repeat(40)],
    ["d".repeat(40), head],
    [head],
  ])
    assert.throws(
      () => verifyMerge({ tested: merge, parents, head, base }),
      /current PR merge/,
    );
});
test("detection uses actual merge parents and propagates API/selection failures", async () => {
  const context = {
    eventName: "pull_request",
    payload: event(),
    repo: { owner: "synonymdev", repo: "bitkit-ios" },
  };
  const github = {
    rest: {
      pulls: { get: async () => ({ data: event().pull_request }) },
      git: { getRef: async () => ({ data: { object: { sha: base } } }) },
    },
  };
  const git = (args) =>
    args[0] === "rev-parse"
      ? merge
      : args[0] === "show"
        ? `${base} ${head}`
        : "Bitkit/Wallet.swift\0";
  assert.deepEqual(await inspect({ github, context }, git), {
    code: true,
    tested: merge,
    head,
    base,
    reason: "verified PR merge",
  });
  const changed = {
    ...context,
    payload: {
      ...event(),
      pull_request: { ...event().pull_request, head: { sha: "d".repeat(40) } },
    },
  };
  await assert.rejects(
    inspect({ github, context: changed }, git),
    /head changed/,
  );
  github.rest.git.getRef = async () => {
    throw Error("API unavailable");
  };
  await assert.rejects(inspect({ github, context }, git), /API unavailable/);
});
test("manual dispatch pins the actual workflow revision", async () => {
  const context = { eventName: "workflow_dispatch", payload: {}, sha: merge };
  assert.equal((await inspect({ context }, () => merge)).tested, merge);
  await assert.rejects(
    inspect({ context }, () => head),
    /dispatched revision/,
  );
});
test("aggregation distinguishes path miss from failed, skipped or cancelled work", () => {
  assert.equal(verdict("success", "false", "skipped").pass, true);
  assert.equal(verdict("success", "true", "success").pass, true);
  for (const status of ["failure", "cancelled", "skipped"]) {
    assert.equal(verdict(status, "false", "skipped").pass, false);
    assert.equal(verdict("success", "true", status).pass, false);
  }
  assert.equal(verdict("success", "", "success").pass, false);
});
test("shadow has distinct names, one attempt, read permissions, no scheduled trigger or required-gate edits", () => {
  const workflow = fs.readFileSync(
    path.join(__dirname, "../workflows/e2e-smoke-shadow.yml"),
    "utf8",
  );
  assert.match(workflow, /name: e2e-smoke-shadow-status/);
  assert.match(workflow, /E2E_MAX_ATTEMPTS: ['" ]?1['"]?/);
  assert.match(workflow, /contents: read/);
  assert.doesNotMatch(
    workflow,
    /pull_request_target|checks: write|schedule:|continue-on-error: true/,
  );
  assert.match(workflow, /if: always\(\)/);
  assert.match(workflow, /--spec.*smoke\.e2e\.ts/);
});

test("build-generator-only changes schedule smoke", () => {
  assert.equal(
    needsSmoke("pull_request", event(), [
      "scripts/generate-plural-localizations.swift",
    ]),
    true,
  );
});
test("always diagnostic collector creates artifacts after checkout/setup failure and preserves failed build output", (t) => {
  const directory = fs.mkdtempSync(
    path.join(os.tmpdir(), "shadow-diagnostics-"),
  );
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const workflow = fs.readFileSync(
    path.join(__dirname, "../workflows/e2e-smoke-shadow.yml"),
    "utf8",
  );
  const section = workflow
    .split("      - name: Collect setup and build diagnostics\n")[1]
    .split("      - name: Upload smoke evidence")[0];
  assert.match(section, /if: always\(\)/);
  const script = section
    .split("        run: |\n")[1]
    .split("\n")
    .map((line) => line.replace(/^          /, ""))
    .join("\n");
  const metadata = {
    job: "failure",
    install: "failure",
    build: "skipped",
    appSha: merge,
  };
  const invoke = () =>
    execFileSync("bash", ["-e", "-o", "pipefail", "-c", script], {
      cwd: directory,
      env: {
        ...process.env,
        RUNNER_TEMP: directory,
        DIAGNOSTICS: JSON.stringify(metadata),
      },
    });
  invoke(); // No checkout or build log exists yet.
  const report = path.join(
    directory,
    "bitkit-e2e-tests/artifacts/reporting/setup.json",
  );
  assert.deepEqual(JSON.parse(fs.readFileSync(report, "utf8")), metadata);
  fs.writeFileSync(
    path.join(directory, "ios-smoke-build.log"),
    "error: fixture build failed\n",
  );
  metadata.install = "success";
  metadata.build = "failure";
  invoke();
  assert.equal(
    fs.readFileSync(
      path.join(directory, "bitkit-e2e-tests/artifacts/ios-smoke-build.log"),
      "utf8",
    ),
    "error: fixture build failed\n",
  );
  assert.equal(JSON.parse(fs.readFileSync(report, "utf8")).build, "failure");
  assert.match(workflow, /set -o pipefail/);
  assert.match(
    workflow,
    /build 2>&1 \| tee "\$RUNNER_TEMP\/ios-smoke-build.log" \| xcbeautify/,
  );
});
