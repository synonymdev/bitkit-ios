# iOS E2E CI

`e2e-tests.yml` is the entry point for PR, manual and nightly E2E selection. The shared policy and runner live in `synonymdev/bitkit-e2e-tests`; see [selection and reporting](https://github.com/synonymdev/bitkit-e2e-tests/blob/main/docs/inventory-reporting.md).

The base gate is exactly `send_1`, `send_2`, `lightning_1`, `transfer_2`, `boost_2`. Changed files automatically add risk coverage. Broad or unclassified changes expand to all applicable lanes. The required `e2e-status` aggregates every selected job. Existing unit and native integration workflows remain separate and unchanged. Android is unchanged.

Every night at 03:00 UTC the entry point runs all applicable local, staging and extended migration cases, even for an unchanged revision. The existing staging/migration workflows provide reusable execution and retain standalone manual dispatch. They no longer schedule duplicate runs. Known skipped cases and unsupported mainnet fixtures are reported as gaps, not successful coverage.

Manual validation uses the branch containing the changed workflow:

```sh
gh workflow run e2e-tests.yml --ref codex/264-inventory-shadow \
  -f e2e_branch=codex/264-inventory-shadow -f selection=base -f shards=1
```

To test a PR merge, including a stacked PR, also pass `-f pr=NUMBER -f selection=auto`. The merge must match the PR's actual base and head. `selection=full` exercises all lanes. The optional `shards=2` experiment applies only to manual local execution; automatic runs use one shard. Each shard has isolated infrastructure and shares the same built local app. Staging/migration share one network app build.

Attempts are bounded to three, stop on success, and retain first-failure evidence. Missing selected cases or failed selected jobs fail the aggregate status. Builds are capped at 40 minutes, execution jobs at 135 minutes and runner attempts at 40 minutes. Diagnostic artifacts expire after seven days. Compare end-to-end duration and billed Mac/backend usage before making two shards automatic.

Land the E2E producer first. Validate these branches before merging this consumer. The migration fixture workflow is pinned to the producer commit that supports immutable source selection, allowing full branch validation before either PR merges. There is no shadow workflow and no additional smoke-test replacement.
