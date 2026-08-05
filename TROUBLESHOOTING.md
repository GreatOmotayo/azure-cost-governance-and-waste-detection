# Troubleshooting & Decision Log — Azure Cost Governance & Waste Detection

A record of every real issue hit while building and deploying this project, why
it happened, and how it was resolved. Kept in chronological order so the
narrative of "what broke, what we tried, what actually fixed it" stays intact
— useful for future-me, for anyone reviewing this repo, and as a reference for
the equivalent problem showing up on a future project.

---

## 1. Terraform backend init — malformed YAML line continuation

**Symptom:** `terraform init` failed with `Too many command line arguments.
Did you mean to use -chdir?`

**Root cause:** the GitHub Actions `run:` step used a plain YAML scalar
instead of a literal block scalar (`|`). YAML folds line breaks into single
spaces in a plain scalar, so the `\` continuation characters became literal
text rather than real shell line continuations — each `-backend-config` flag
ended up glued onto a malformed argument.

**Fix:** switch the `run:` step to `run: |` so real newlines are preserved and
the backslash continuations behave like they would in a normal shell script.

---

## 2. RBAC — three separate permission gaps for the same OIDC identity

Each of these threw `AuthorizationFailed` against a different Azure
control-plane, discovered one at a time as Terraform reached each resource
type:

| Resource type | Action needed | Role granted |
|---|---|---|
| Policy Definitions | `Microsoft.Authorization/policyDefinitions/write` | `Resource Policy Contributor` |
| Role Assignments (RG scope) | `Microsoft.Authorization/roleAssignments/write` | `User Access Administrator` (RG scope) |
| Role Assignments (subscription scope) | same action, broader scope | `User Access Administrator` widened to subscription scope |

**Decision:** the subscription-scope grant was necessary, not accidental
over-permissioning — `azurerm_role_assignment.function_reader` intentionally
grants the waste-scanner Function's identity `Reader` at the subscription
level, since a waste-detection tool needs visibility across the whole
subscription, not just one resource group.

**Lesson:** Azure separates "manage resources," "manage policy," and "manage
access" into three distinct control planes. `Contributor` alone doesn't cover
the latter two — a CI/CD identity that provisions RBAC or Policy resources as
part of its own Terraform needs explicit grants for each.

---

## 3. Cost Management export — static start date going stale

**Symptom:** `Invalid schedule recurrencePeriod; 'from' value cannot be in
the past.`

**Root cause:** `recurrence_period_start_date` was hardcoded to a fixed
timestamp, which will always eventually fall in the past relative to
whenever `apply` actually runs.

**Fix:** use `timestamp()` for the start date with a `lifecycle {
ignore_changes = [recurrence_period_start_date] }` block, so the resource
self-heals on first apply and then leaves the schedule alone afterward
instead of trying to recreate the export on every subsequent run.

---

## 4. VM SKU capacity restriction

**Symptom:** `SkuNotAvailable: Standard_B2s ... currently not available in
location 'centralus'`.

**Root cause:** subscription-level capacity restriction on that specific
SKU/region combination (`az vm list-skus` confirmed
`NotAvailableForSubscription`).

**Fix:** switched to `Standard_B2s_v2`, same region, same tier — a newer SKU
generation with no restriction, functionally equivalent for a
stopped/deallocated waste-detection demo VM.

---

## 5. `azurerm_role_assignment` — provider/read consistency race

**Symptom:** `Provider produced inconsistent result after apply — Root
object was present, but now absent.`

**Root cause:** Azure RBAC is eventually consistent. The role assignment was
created successfully, but the provider's immediate read-back to confirm state
ran before Azure AD/RBAC had finished propagating, especially likely on a
freshly created managed identity.

**Fix:** `skip_service_principal_aad_check = true` (skips AAD validation at
write time) plus a `time_sleep` resource between creating the identity and
assigning the role (reduces the odds of hitting the read-back race in the
first place). Belt-and-suspenders — they address slightly different points
in the same underlying propagation-lag problem.

---

## 6. Circular dependency — subnet ↔ NIC

**Symptom:** `Cycle: azurerm_network_interface.waste_vm_nic,
azurerm_subnet.project_subnet`

**Root cause:** self-inflicted. An earlier attempt to fix a subnet-delete
ordering issue added `depends_on = [azurerm_network_interface.waste_vm_nic]`
to the subnet resource — but the NIC already depends on the subnet via
`subnet_id`, so this created a direct two-node cycle.

**Fix:** removed the `depends_on`. The implicit reference
(`subnet_id = azurerm_subnet.project_subnet.id`) was already sufficient for
Terraform to infer correct create/destroy ordering with zero extra
configuration.

**Lesson:** don't add explicit `depends_on` to "fix" ordering issues without
first confirming the implicit dependency isn't already correct — it's a common
way to introduce a cycle that didn't exist before.

---

## 7. AzureRM provider major-version churn (Node 22 → v4.23 → v5.0.1 → back to v4.81)

**Chain of events:**
1. Needed Node 22 support on `azurerm_linux_function_app` → required bumping
   the provider past `4.23.0` (Node 22 validation fix landed there).
2. An unconstrained `terraform init -upgrade` (no upper bound on the version
   constraint) pulled the newly-released major version `5.0.1` instead of
   staying on the 4.x line.
3. AzureRM 5.0 changed `azurerm_storage_container` to require
   `storage_account_id` and reject `storage_account_name` — a real breaking
   change, correctly diagnosed and fixed.
4. But a **separate, genuine provider bug** in the 5.0.x line caused ID
   parsing errors on `azurerm_storage_container` specifically when migrating
   existing state from pre-4.81 — confirmed via an open upstream GitHub issue
   with the identical symptom.
5. **Decision:** pin back to `~> 4.34` (later confirmed working at `4.81.0`)
   rather than wait for or work around the v5 regression, since Node 22
   support only required `>= 4.23.0`, not v5.

**Lesson:** `-upgrade` with a loose (`>=`) constraint can silently jump a
major version. Pin with an upper bound (`~>`) for anything beyond a quick
local test, and treat major-version bumps as a deliberate, isolated upgrade
step — not something to do mid-troubleshooting for an unrelated fix.

---

## 8. Zero functions indexed — the long chase

This was the deepest rabbit hole: `func-waste-scanner-j7jpgg` deployed
successfully (green CI, `Sync Trigger call was successful`), but the Portal's
Functions blade, `az functionapp function list`, and the host's own
`/admin/functions` endpoint all showed **zero functions**, with no error
surfaced anywhere in Azure.

**Ruled out one at a time, in order:**
- Portal navigation confusion (it wasn't — genuinely zero functions)
- `package.json`'s `main` glob not matching the actual compiled output path
  (real bug, fixed: `dist/src/functions/*.js` → `dist/src/*.js` once source
  files were confirmed to live directly under `src/`, not `src/functions/`)
- Missing `AzureWebJobsFeatureFlags = EnableWorkerIndexing` app setting
  (real gap, fixed — required for the Node.js v4 programmatic model to
  discover `app.timer()`/`app.http()` registrations on Linux Consumption)
- Missing `host.json` at the package root (real gap, fixed — mandatory file,
  its absence meant the host had no configuration to recognize the package
  as a function app at all)
- Provider version drift, stale caches, Kudu access (all dead ends — package
  contents, app settings, and provider versions were eventually confirmed
  correct via direct blob inspection and `terraform providers schema`)

**Actual root cause, found only by running `func start` locally:**

```
Worker was unable to load entry point "dist/src/reportBuilder.js":
Package subpath './dist/commonjs/emailClient' is not defined by "exports"
in .../node_modules/@azure/communication-email/package.json
```

`reportBuilder.ts` imported directly from the package's internal compiled
path:
```typescript
import { EmailClient } from "@azure/communication-email/dist/commonjs/emailClient";
```
instead of the public top-level export:
```typescript
import { EmailClient } from "@azure/communication-email";
```

Node's strict `exports` map in the package blocks reaching into internal
paths directly, so this throws on `require()` regardless of which version of
the package is installed. Because the Node.js v4 model indexes all functions
from a single discovery pass, one file throwing on load silently prevented
**every** function in the app from registering — including the completely
unrelated `wasteScanner.js`.

**Lesson:** when a deployed Azure Function App reports healthy host status
(`state: Running`, no errors) but shows zero registered functions, and
static package inspection (files, settings, provider versions) all check
out clean, the fastest path to the real answer is running `func start`
locally — it surfaces language-worker-level load errors immediately that
never make it into Azure's own logging or host status API.

---

## 9. Application Insights blocked by our own tag policy

**Symptom:** `Resource 'func-waste-scanner-j7jpgg' was disallowed by policy.
Require owner and costCenter tags`

**Root cause:** the Portal's "Add Application Insights" flow auto-provisions
a new Application Insights resource behind the scenes, without exposing tag
fields — and this project's own `require-cost-governance-tags` policy
(deployed as part of this project, see section 2) correctly blocked the
untagged resource.

**Fix:** create the Application Insights resource explicitly via CLI/
Terraform with tags included, then link its connection string to the
Function App as an app setting, rather than letting the Portal auto-provision
it.

---

## 10. Communication Services — two-part email failure

Confirmed working end-to-end only after fixing two independent gaps, both
required:

**10a. RBAC — management-plane role insufficient for data-plane action**

`Contributor` was granted on the Communication Service resource, which
covers managing the resource itself but not the data-plane action of
actually sending an email via `DefaultAzureCredential`. Fixed by granting
`Communication and Email Service Owner` specifically.

**10b. Domain never linked to the Communication Service resource**

Even with correct RBAC, sends still failed. The Email Communication Service
resource (`ecs-waste-scanner`) and its Azure-managed domain were fully
provisioned and verified — but never linked to the Communication Service
resource (`acs-waste-scanner`) that the code actually authenticates against.
`az communication show` confirmed `linkedDomains` was entirely absent.
Fixed via `az resource update --set properties.linkedDomains=[...]`.

**Lesson:** provisioning the Email Service, its domain, the Communication
Service, and the link between them are four separate steps. Verifying "the
domain exists and is Succeeded" is necessary but not sufficient — the link
step is easy to miss since nothing in the Portal or CLI output calls it out
as missing; the failure just looks identical to an RBAC problem.

---

## Outcome

Both `wasteScanner` and `reportBuilder` are deployed, indexed, and confirmed
working end-to-end via manual invocation:
- `wasteScanner`: Resource Graph query → 3 real waste items found
  (~$28.64/month) → email delivered
- `reportBuilder`: cost export read → Excel workbook built → blob uploaded →
  email delivered

See `terraform-fixes-to-apply.tf` for everything that was fixed manually via
CLI during this process and still needs to be folded into the Terraform
config so it isn't lost or reverted on a future `apply`.
