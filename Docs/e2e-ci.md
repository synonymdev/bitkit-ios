# iOS E2E CI

`e2e-tests.yml` is the entry point for PR, manual and nightly E2E selection. This repo owns [the path policy](../.github/e2e-policy.json), [selector](../.github/scripts/e2e-selection.cjs) and [policy tests](../.github/scripts/e2e-selection.test.cjs). The shared E2E repo owns case definitions, inventory, fixtures and execution/reporting, not iOS paths.

The base gate is exactly `send_1`, `send_2`, `lightning_1`, `transfer_2`, `boost_2`. Changed files automatically add risk coverage. The required `e2e-status` aggregates every selected job. Existing unit and native integration workflows remain separate and unchanged. Android is unchanged.

## Policy ownership and maintenance

The selector loads `.github/e2e-policy.json` from the **tested app checkout**, not the E2E branch. `selection.json` records that app/policy SHA, the policy file digest, E2E SHA, exact case IDs and matching rules. Feature directories inherit their domain classification; services, managers, models and utilities use explicit files. There is no directory-wide `Services/` or `Models/` escalation.

| Actual changed path | Coverage beyond the five-case base |
| --- | --- |
| `Bitkit/Services/Widgets/NewsService.swift` | `widgets_1–3`, `settings_12` |
| `Bitkit/Services/PaykitPaymentRequestService.swift` | Six Pubky/Paykit staging cases; no migration |
| `Bitkit/Services/Trezor/TrezorService.swift` | Three active hardware cases; no staging/migration |
| `Bitkit/Managers/FeeEstimatesManager.swift` | `boost_1`, `onchain_3`, `settings_03` |
| `Bitkit/Services/BackupService.swift` | Five onboarding/backup/security cases plus six migration cases; no staging |
| `Bitkit/Services/CoreService.swift` | Full coverage: shared wallet/account state affects all lanes |

Only named app-wide wallet/lifecycle files and build/dependency/E2E orchestration configuration select all lanes. At the policy introduction, this means 27 of 619 `Bitkit` Swift files, including three of 76 service files (`CoreService`, `LightningService`, `ServiceQueue`). These are a source-tree audit, not a runtime or billing estimate. Changes to several domains union their coverage and execute overlapping cases once.

Every PR, including drafts and stacks, gets a cheap Linux `E2E selection policy` check. It verifies every tracked path has a classification, explicit file/prefix entries still exist, and referenced cases are runnable in the selected E2E inventory. Main selection runs the same validation before any paid build. A new unclassified service or moved file fails with its path and a request to update the policy in the same iOS PR. It does not silently select base or launch every lane. Old and new rename paths contribute rules from both the base and tested policy, retaining coverage when a path mapping changes during a refactor.

Documentation, native-test and selection-policy-only changes need no device jobs; existing native/lint checks and policy tests cover them. Presentation/resource changes run the base gate. USDT-specific paths record the lack of existing USDT E2E coverage and keep Bitcoin regression coverage; running unrelated Bitcoin tests would not prove USDT behavior. Native/integration tests must cover those feature changes.

When adding/moving code, edit this JSON in the same PR, use an existing feature directory or add an explicit file classification with its reason, then run:

```sh
E2E_TEST_ROOT=../bitkit-e2e-tests node .github/scripts/e2e-selection.cjs check
E2E_TEST_ROOT=../bitkit-e2e-tests node --test .github/scripts/e2e-selection.test.cjs
```

The E2E checkout must contain the matching inventory. Add a real-path regression example when introducing a new domain mapping. New coverage belongs in the shared E2E repo; app paths do not.

## Execution

Every night at 03:00 UTC the entry point runs all applicable local, staging and extended migration cases, even for an unchanged revision. The existing staging/migration workflows provide reusable execution and retain standalone manual dispatch. They no longer schedule duplicate runs. Known skipped cases and unsupported mainnet fixtures are reported as gaps, not successful coverage.

Manual validation uses the branch containing the changed workflow:

```sh
gh workflow run e2e-tests.yml --ref codex/264-inventory-shadow \
  -f e2e_branch=codex/264-inventory-shadow -f selection=base -f shards=1
```

To test a PR merge, including a stacked PR, also pass `-f pr=NUMBER -f selection=auto`. The merge must match the PR's actual base and head. `selection=full` exercises all lanes. The optional `shards=2` experiment applies only to manual local execution; automatic runs use one shard. Each shard has isolated infrastructure and shares the same built local app. Staging/migration share one network app build.

Attempts are bounded to three, stop on success, and retain first-failure evidence. Missing selected cases or failed selected jobs fail the aggregate status. Builds are capped at 40 minutes, execution jobs at 135 minutes and runner attempts at 40 minutes. Diagnostic artifacts expire after seven days. Compare end-to-end duration and billed Mac/backend usage before making two shards automatic.

Land the E2E producer first. Validate these branches before merging this consumer. The migration fixture workflow is pinned to the producer commit that supports immutable source selection, allowing full branch validation before either PR merges. There is no shadow workflow and no additional smoke-test replacement.
