const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { execFileSync, spawnSync } = require("node:child_process");
const {
  policy,
  select,
  validatePolicy,
  validateTree,
} = require("./e2e-selection.cjs");
const app = path.resolve(__dirname, "../..");
const e2e = path.resolve(
  process.env.E2E_TEST_ROOT || path.join(app, "../bitkit-e2e-tests"),
);
const cases = JSON.parse(
  fs.readFileSync(path.join(e2e, "test/inventory.json"), "utf8"),
).cases;
const tracked = execFileSync("git", ["-C", app, "ls-files", "-z"], {
  encoding: "utf8",
})
  .split("\0")
  .filter(Boolean);
const pick = (files, options = {}) => select(cases, { files, ...options });

test("policy covers the actual iOS tree and contains no stale paths or case IDs", () =>
  validateTree(policy, tracked, cases));
test("base remains exactly the five existing cases", () =>
  assert.deepEqual([...policy.base].sort(), [
    "boost_2",
    "lightning_1",
    "send_1",
    "send_2",
    "transfer_2",
  ]));

for (const [file, added, staging, migration] of [
  [
    "Bitkit/Services/Widgets/NewsService.swift",
    ["widgets_1", "widgets_2", "widgets_3", "settings_12"],
    false,
    false,
  ],
  [
    "Bitkit/Models/NewsWidgetData.swift",
    ["widgets_1", "widgets_2", "widgets_3", "settings_12"],
    false,
    false,
  ],
  ["Bitkit/Services/PaykitPaymentRequestService.swift", [], true, false],
  ["Bitkit/Managers/ContactsManager.swift", [], true, false],
  [
    "Bitkit/Services/Trezor/TrezorService.swift",
    ["hardware_wallet_1", "hardware_wallet_2", "hardware_wallet_4"],
    false,
    false,
  ],
  [
    "Bitkit/Managers/FeeEstimatesManager.swift",
    ["boost_1", "onchain_3", "settings_03"],
    false,
    false,
  ],
  [
    "Bitkit/Services/BackupService.swift",
    ["backup_1", "onboarding_1", "onboarding_2", "security_1", "settings_07"],
    false,
    true,
  ],
  [
    "Bitkit/Services/ElectrumConfigService.swift",
    ["settings_10"],
    false,
    false,
  ],
  ["Bitkit/Services/RgsConfigService.swift", ["settings_11"], false, false],
])
  test(`actual ${file} selects exact domain coverage`, () => {
    assert.ok(tracked.includes(file), "Example must exist in the app");
    const s = pick([file]);
    assert.deepEqual(s.ids, [...new Set([...policy.base, ...added])].sort());
    assert.equal(s.staging, staging);
    assert.equal(s.migration, migration);
  });

test("on-chain service expands payment coverage without unrelated staging/migration", () => {
  const s = pick(["Bitkit/Services/OnchainSendAttemptService.swift"]);
  assert.deepEqual(
    s.ids,
    [...new Set([...policy.base, ...policy.groups.send])].sort(),
  );
  assert.equal(s.staging, false);
  assert.equal(s.migration, false);
});
for (const f of [
  "Bitkit/Services/CoreService.swift",
  "Bitkit/ViewModels/WalletViewModel.swift",
  "Bitkit.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
])
  test(`explicit shared dependency ${f} expands all lanes`, () => {
    const s = pick([f]);
    assert.equal(s.ids.length, 42);
    assert.equal(s.staging, true);
    assert.equal(s.migration, true);
  });
test("unknown service/new area fails cheaply, never silently selects base or full", () => {
  for (const f of [
    "Bitkit/Services/NewService.swift",
    "Bitkit/NewArea/Payment.swift",
  ])
    assert.throws(() => pick([f]), /Unclassified.*e2e-policy/s);
});
test("new files inside a feature directory inherit its classification", () => {
  assert.deepEqual(
    pick(["Bitkit/Services/Widgets/NewService.swift"]).ids,
    pick(["Bitkit/Services/Widgets/NewsService.swift"]).ids,
  );
});
test("removed paths and obsolete IDs cannot leave stale rules unnoticed", () => {
  assert.throws(
    () =>
      validateTree(
        policy,
        tracked.filter((f) => f !== "Bitkit/Services/CoreService.swift"),
        cases,
      ),
    /Stale policy paths.*CoreService/s,
  );
  assert.throws(
    () =>
      validateTree(
        policy,
        [...tracked, "Bitkit/Services/NewService.swift"],
        cases,
      ),
    /Unclassified paths.*NewService/s,
  );
  assert.throws(
    () =>
      validatePolicy(
        policy,
        cases.filter((c) => c.id !== "send_2"),
      ),
    /unavailable case: send_2/,
  );
});
test("renames preserve old domain and include new domain with base policy", () => {
  const old = structuredClone(policy),
    current = structuredClone(policy);
  const f = "Bitkit/Services/PaykitPaymentRequestService.swift";
  for (const r of current.rules) r.files = r.files.filter((x) => x !== f);
  const s = pick([f, "Bitkit/Services/Widgets/Request.swift"], {
    currentPolicy: current,
    previousPolicy: old,
  });
  assert.equal(s.staging, true);
  assert.ok(s.ids.includes("widgets_1"));
  assert.ok(s.reasons.some((r) => r.file === f && r.policy === "base"));
});
test("changing the policy cannot waive existing coverage on the same code diff", () => {
  const current = structuredClone(policy);
  for (const r of current.rules)
    if (r.files.includes("Bitkit/Services/PaykitPaymentRequestService.swift"))
      r.groups = [];
  const s = pick(["Bitkit/Services/PaykitPaymentRequestService.swift"], {
    currentPolicy: current,
    previousPolicy: policy,
  });
  assert.equal(s.staging, true);
});
test("docs/native-test/policy-only changes need no paid jobs", () => {
  for (const f of [
    "Docs/e2e-ci.md",
    "BitkitTests/CurrencyTests.swift",
    ".github/e2e-policy.json",
  ]) {
    const s = pick([f]);
    assert.equal(s.code, false);
    assert.deepEqual(s.matrix, []);
  }
});
test("USDT selection records missing coverage instead of pretending all Bitcoin tests cover it", () => {
  const s = pick(["Bitkit/Managers/UsdtWalletManager.swift"]);
  assert.deepEqual(s.ids, [...policy.base].sort());
  assert.ok(s.coverageNotes[0].includes("USDT"));
});
test("nightly/full include all existing applicable lanes with no changes; gaps stay explicit", () => {
  for (const mode of ["full", "nightly"]) {
    const s = pick([], { mode });
    assert.equal(s.ids.length, 42);
    assert.equal(s.staging, true);
    assert.equal(s.migration, true);
    assert.ok(s.gaps.some((g) => g.id === "transfer_1"));
    assert.ok(!s.ids.includes("transfer_1"));
  }
});
test("two shards partition cases exactly and retain spec lifecycle grouping", () => {
  const s = pick([], { mode: "full", shards: 2 });
  assert.equal(s.matrix.length, 2);
  assert.deepEqual(s.matrix.flatMap((x) => x.ids).sort(), s.ids);
  for (const f of new Set(cases.map((c) => c.file))) {
    const ids = cases.filter((c) => c.file === f).map((c) => c.id);
    assert.ok(
      s.matrix.filter((b) => b.ids.some((id) => ids.includes(id))).length <= 1,
    );
  }
});

test("actual CLI uses tested app policy and pinned E2E inventory; rejects drift before output", (t) => {
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), "ios-selection-"));
  t.after(() => fs.rmSync(temp, { recursive: true, force: true }));
  const root = path.join(temp, "app");
  fs.mkdirSync(path.join(root, ".github/scripts"), { recursive: true });
  fs.copyFileSync(
    path.join(__dirname, "e2e-selection.cjs"),
    path.join(root, ".github/scripts/e2e-selection.cjs"),
  );
  // A tiny app-owned policy proves the CLI does not load rules from the E2E checkout.
  const p = {
    schemaVersion: 1,
    base: policy.base,
    groups: { widgets: policy.groups.widgets },
    rules: [
      {
        name: "widget-source",
        files: ["Widget.swift"],
        prefixes: [],
        groups: ["widgets"],
      },
      {
        name: "policy",
        files: [".github/e2e-policy.json", ".github/scripts/e2e-selection.cjs"],
        prefixes: [],
        groups: [],
        skip: true,
      },
    ],
  };
  fs.writeFileSync(
    path.join(root, ".github/e2e-policy.json"),
    JSON.stringify(p),
  );
  fs.writeFileSync(path.join(root, "Widget.swift"), "// fixture");
  execFileSync("git", ["init", "-q", root]);
  execFileSync("git", ["-C", root, "add", "."]);
  // Only need a tree/HEAD for identity; use the already signed app commit as HEAD
  // in a shared object repository, rather than create an unsigned test commit.
  const objects = execFileSync(
    "git",
    ["-C", app, "rev-parse", "--path-format=absolute", "--git-path", "objects"],
    { encoding: "utf8" },
  ).trim();
  fs.mkdirSync(path.join(root, ".git/objects/info"), { recursive: true });
  fs.writeFileSync(
    path.join(root, ".git/objects/info/alternates"),
    objects + "\n",
  );
  const head = execFileSync("git", ["-C", app, "rev-parse", "HEAD"], {
    encoding: "utf8",
  }).trim();
  execFileSync("git", ["-C", root, "update-ref", "HEAD", head]);
  const event = path.join(temp, "event.json");
  fs.writeFileSync(event, "{}");
  const env = {
    ...process.env,
    E2E_TEST_ROOT: e2e,
    GITHUB_EVENT_PATH: event,
    GITHUB_EVENT_NAME: "workflow_dispatch",
    E2E_SELECTION: "base",
  };
  const run = () =>
    spawnSync(
      process.execPath,
      [path.join(root, ".github/scripts/e2e-selection.cjs")],
      { cwd: temp, env, encoding: "utf8" },
    );
  const r = run();
  assert.equal(r.status, 0, r.stderr);
  const s = JSON.parse(
    fs.readFileSync(path.join(temp, "selection.json"), "utf8"),
  );
  assert.equal(s.policy.appSha, head);
  assert.equal(s.policy.path, ".github/e2e-policy.json");
  assert.deepEqual(s.ids, [...policy.base].sort());
  fs.unlinkSync(path.join(temp, "selection.json"));
  fs.writeFileSync(path.join(root, "Unknown.swift"), "// new");
  execFileSync("git", ["-C", root, "add", "Unknown.swift"]);
  const bad = run();
  assert.notEqual(bad.status, 0);
  assert.match(bad.stderr, /Unclassified paths: Unknown/);
  assert.ok(!fs.existsSync(path.join(temp, "selection.json")));
});
