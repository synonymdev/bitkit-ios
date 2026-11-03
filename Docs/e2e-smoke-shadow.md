# iOS smoke shadow (#264)

This manual validation workflow observes three fresh-wallet regtest cases. It does not
replace `e2e-status`, alter rulesets, or change existing gates and schedules.
The inventory/reporting and smoke producer in `synonymdev/bitkit-e2e-tests` must
land first, or use matching companion branches in both repositories.

This workflow is **manual-only** (`workflow_dispatch`). Opening, updating or
retargeting a PR, pushing a commit, or changing a build script does not start it.
The existing gates remain the only automatic app gates during validation. Dispatch
against an existing selected revision; there is no need to push a new commit to
validate it. The checkout must match that dispatch's SHA.

After representative manual runs validate the smoke pack, switch the automatic PR
gate in one deliberate change. Do not add an automatic smoke job alongside the old
gate as a rollout phase. Existing nightly coverage continues unchanged.

Each selected run uses one standard hosted Mac, one simulator and one test attempt.
The job is capped at 60 minutes, the build at 30 and tests at 20. A newer manual dispatch on the same ref cancels
an older manual smoke run. Cache access is read-only; evidence retention is seven days.
There are no automatic retries or shards. Manual validation consumes compute only when explicitly dispatched; it does not
add an automatic Mac run to each PR. Do not assume parallelism reduces
billed minutes or that hosted-runner availability guarantees no queue.

Inspect `e2e-smoke-shadow-status`, the Actions summary and `ios-smoke-shadow-*`
artifact. The report records app/E2E revisions, app archive digest, backend identity,
expected IDs, each outcome, first failure and duration. Build/setup failures report
incomplete coverage. Test durations do not include billed build/setup minutes.

Before changing any required check, validate hosted execution, concurrent-run
isolation, representative failures, first-pass reliability and measured end-to-end
latency/cost over an agreed sample. The 10–15 minute smoke target is a measurement
goal, not a claim that this workflow has achieved it. Risk packs, full nightly
orchestration and the two-shard experiment remain later stages.

Local workflow checks:

```sh
node --test .github/scripts/smoke-shadow.test.cjs
actionlint -ignore 'unexpected key "cache-mode" for "job" section' .github/workflows/e2e-smoke-shadow.yml
```

The exception is limited to `cache-mode`, supported by
[GitHub's workflow syntax](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#jobsjob_idcache-mode)
but not recognized by actionlint 1.7.12. Do not remove the read-only restriction to
satisfy the older schema. All other lint diagnostics remain errors.
