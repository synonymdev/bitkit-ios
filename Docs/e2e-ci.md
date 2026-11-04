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
| `Bitkit/Services/BackupService.swift` | Five onboarding/backup/security cases plus six Pubky/Paykit staging cases |
| `Bitkit/Services/CoreService.swift` | All local and staging cases |

Scanner routing explicitly includes Pubky/Electrum and hardware coverage. Backup transport/payload/restore includes profile persistence. The global Keychain is an explicit full-coverage dependency because it owns wallet secrets and Pubky/Paykit state. Shared amount/confirmation and on-chain dispatch include the existing Paykit contact-payment case. These mappings follow actual callers and assertions, not filename similarity.

Only named app-wide wallet/lifecycle files and build/dependency/E2E orchestration configuration select all PR-eligible local and staging cases. At the policy introduction, this means 28 of 619 `Bitkit` Swift files, including three of 76 service files (`CoreService`, `LightningService`, `ServiceQueue`). These are a source-tree audit, not a runtime or billing estimate. Changes to several domains union their coverage and execute overlapping cases once.

Every PR, including drafts and stacks, gets a cheap Linux `E2E selection policy` check. It verifies every tracked path has a classification, explicit file/prefix entries still exist, and referenced cases are runnable in the selected E2E inventory. Main selection runs the same validation before any paid build. A new unclassified service or moved file fails with its path and a request to update the policy in the same iOS PR. It does not silently select base or launch every lane. Old and new rename paths contribute rules from both the base and tested policy, retaining coverage when a path mapping changes during a refactor.

Documentation, native-test and selection-policy-only changes need no device jobs; existing native/lint checks and policy tests cover them. Presentation/resource changes run the base gate. USDT-specific paths record the lack of existing USDT E2E coverage and keep Bitcoin regression coverage; running unrelated Bitcoin tests would not prove USDT behavior. Native/integration tests must cover those feature changes.

When adding/moving code, edit this JSON in the same PR, use an existing feature directory or add an explicit file classification with its reason, then run:

```sh
E2E_TEST_ROOT=../bitkit-e2e-tests node .github/scripts/e2e-selection.cjs check
E2E_TEST_ROOT=../bitkit-e2e-tests node --test .github/scripts/e2e-selection.test.cjs
```

The E2E checkout must contain the matching inventory. Add a real-path regression example when introducing a new domain mapping. New coverage belongs in the shared E2E repo; app paths do not.

## Execution

Two independent workflows run at 03:00 UTC. `e2e-tests.yml` runs 42 local and six staging cases. `e2e_migration.yml` builds its own network app and runs all six migrations with its own result. The migration workflow also runs on each push to `release-*` and supports its own manual dispatch for diagnosis.

Manual validation uses the branch containing the changed workflow:

```sh
gh workflow run e2e-tests.yml --ref codex/264-inventory-shadow \
  -f e2e_branch=codex/264-inventory-shadow -f selection=base -f shards=1
```

To test an open same-repository PR merge, including a stacked PR, also pass `-f pr=NUMBER -f selection=auto`. The merge must match the PR's actual base and head. `selection=full` runs the local and staging suites. Manual E2E and PR merge runs use local and staging coverage. The optional `shards=2` experiment applies only to manual local execution; automatic runs use one shard. Each shard has isolated infrastructure and shares the same built local app. The staging job uses its network app build.

Attempts are bounded to three, stop on success, and retain first-failure evidence. Missing selected cases or failed selected jobs fail the aggregate status. Builds are capped at 40 minutes; execution budgets depend on the selected pack as described below. Diagnostic artifacts, including RN wallet preparation logs, expire after seven days; prepared wallet environments expire after one day. Compare end-to-end duration and billed Mac/backend usage before making two shards automatic.

Land the E2E producer first. Validate these branches before merging this consumer. The migration fixture workflow is pinned to the producer commit that supports immutable source selection, allowing full branch validation before either PR merges. There is no shadow workflow and no additional smoke-test replacement.

Local shards with 6–30 cases allow 90 minutes per attempt within a 285-minute job and five-hour backend expiry. Larger shards allow 110 minutes per attempt within a 345-minute job and six-hour backend expiry. Both sizes allow three attempts. Base-sized local selections retain 40-minute attempts and a 135-minute job; the six-case staging pack also uses 90-minute attempts within 285 minutes. Individual migration cases retain 40-minute attempts and 135-minute jobs. The iOS selector owns these budgets and the shared runner seals its attempt limit into the run plan. Limits are ceilings, not reservations: success stops retries and cleanup destroys the backend immediately.
