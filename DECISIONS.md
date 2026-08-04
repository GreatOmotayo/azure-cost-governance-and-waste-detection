# Decision Log — Automated Cost Governance & Waste Detection

Each entry: the decision, the alternatives considered, and why the chosen option won.
Logged as decisions were made during the build, not written retroactively.

---

## D001 — Project scope: governance + detection only
**Decision:** Scope this project to tagging policy enforcement, budget alerts, and automated
waste detection/reporting. Autoscaling and Azure Advisor-driven right-sizing were split out
as separate, later concerns.

**Alternatives considered:** A single mega-project covering governance, autoscaling, waste
detection, and Advisor-driven optimization all at once.

**Why this won:** Autoscaling is a cost-*optimization* technique (how a workload behaves),
not a cost-*governance* mechanism (oversight and accountability of spend) — including it
diluted the project's core story. Advisor-driven optimization requires days of usage
telemetry before producing recommendations, which would have made this project impossible
to demo on request. Narrowing the scope produced a sharper, fully self-contained story and
removed the only multi-day dependency from the build.

---

## D002 — Correction: Reserved Instance / Spot VM content removed
**Original entry (in error):** documented a decision to demonstrate Spot VMs instead of
purchasing a Reserved Instance.

**Why this was wrong for this project:** that content belonged to the earlier, broader draft
of this work, before the project was split into two (see D001). Reserved Instances, Spot
VMs, and Azure Advisor-driven right-sizing all belong to a separate, later project
("Cost Optimization with Azure Advisor & Right-Sizing") — not to this one. Nothing in this
project's Terraform creates a Spot VM; the seeded waste VM (see D006) is a plain VM
deliberately left in a stopped-but-not-deallocated state, which is an unrelated concept.

**Correction:** entry removed from scope. Left visible here, rather than deleted outright,
so the log stays an honest record rather than quietly rewriting history.

---

## D003 — Structural waste, not performance waste
**Decision:** The waste-scanner targets only structural waste patterns — unattached disks,
unassociated public IPs, and stopped-but-not-deallocated VMs — all detectable instantly via
a single Resource Graph query.

**Alternatives considered:** Including an intentionally oversized, "hot" VM whose waste is
proven via CPU utilization trends (as in an earlier, broader draft of this project).

**Why this won:** Performance-based waste requires days of accumulated telemetry before
Azure Advisor (or any trend-based detection) can flag it meaningfully. Structural waste is a
fact about resource *state*, checkable the moment the resource exists — no waiting period,
fully demoable on demand.

---

## D004 — Single resource group, subscription-scoped governance
**Decision:** Compute and Function resources live in one resource group
(`rg-cost-governance-waste-detection`). The tagging Policy and Budget are assigned at
**subscription** scope.

**Why:** Governance tooling is cheap to scope broadly — it's just a scope parameter.
Compute resources are what cost money and take effort to manage, so those stay centralized.
This demonstrates subscription-wide governance without subscription-wide operational
overhead.

---

## D005 — Custom tagging Policy, not two built-ins
**Decision:** One custom Azure Policy definition checks for both `owner` and `costCenter`
tags in a single rule, with a parameterized `effect` (Deny/Audit/Disabled).

**Alternatives considered:** Two separate built-in "require a tag" policy assignments.

**Why this won:** A single custom rule is easier to reason about than two assignments, and
critically, a custom rule supports a parameterized effect — built-ins don't. The
`tag_policy_effect` variable lets the policy be toggled to `Audit` during active development
and back to `Deny` before a recorded demo, without touching the underlying rule.

---

## D006 — Stopped-but-not-deallocated VM via a scoped CLI exception
**Decision:** Use a `null_resource` with a `local-exec` provisioner to run
`az vm stop --skip-shutdown` after Terraform creates the demo VM, since Terraform's
`azurerm_linux_virtual_machine` resource has no way to declare this specific billing state.

**Why:** This is one of the most common and relatable real-world Azure cost traps — stopping
a VM from the OS still leaves it billed unless explicitly deallocated. Rather than hide the
one place Terraform's declarative model falls short, the CLI exception is called out
explicitly as a deliberate, honest workaround.

---

## D007 — Managed Identity everywhere, no stored secrets
**Decision:** The Function App authenticates to Resource Graph, Blob Storage, and
Communication Services entirely via System-Assigned Managed Identity. GitHub Actions
authenticates to Azure via OIDC federated credentials. No API keys, connection strings, or
service-principal secrets exist anywhere in the project.

**Alternatives considered:** A service principal with a client secret (for CI/CD) and
SendGrid or SMTP with an API key (for email).

**Why this won:** Every stored secret is a rotation burden and a leak risk. Managed Identity
and OIDC both use short-lived, automatically-issued tokens tied to a verified identity
(the Function App, or a specific GitHub repo/branch) instead. This is a single, consistent
security posture applied across the entire project, not a one-off choice.

---

## D008 — RBAC: least privilege, matched per identity
**Decision:** The Function's runtime identity has `Reader` at subscription scope (for
Resource Graph queries) and `Storage Blob Data Contributor` scoped to just its own storage
account. The CI/CD identity has `Contributor` at subscription scope, but gated behind a
manual approval step (`environment: production`) before any `apply` runs.

**Why:** The runtime identity only ever reads data — broader access would increase blast
radius with no functional benefit. The CI/CD identity genuinely needs write access to run
`terraform apply`, so that privilege is matched with a human-review gate instead of being
narrowed artificially.

**Known exception:** the Communication Services role assignment uses `Contributor` (scoped
to just that one resource) because no narrower built-in Azure role currently covers the
send-email data action. Documented as a known trade-off, not an oversight.

---

## D009 — Two independent functions, not a shared data pipeline
**Decision:** The waste-scanner and report-builder each independently query Resource Graph;
the report-builder does not read the scanner's output.

**Alternatives considered:** Scanner writes findings to blob storage; report-builder reads
that file instead of re-querying.

**Why this won:** A shared-store design means a failure in the scanner (e.g., a failed email
send) could silently produce a missing or stale report. Independent queries cost a small
amount of duplicated logic but guarantee the report-builder's correctness never depends on
the scanner having succeeded. Accepted trade-off: the two functions could report slightly
different waste counts if resources change between their run times — considered minor and
even informative at a weekly cadence.

---

## D010 — Native Cost Management Export, not a custom billing API script
**Decision:** Use Azure's built-in scheduled Cost Management Export feature to produce the
weekly billing CSV, rather than writing custom code to call the Cost Management Query API.

**Why:** Azure already provides this exact capability as a managed, zero-maintenance
feature. Writing custom code to replicate it would be pure reinvention. Recognizing when to
use a platform feature instead of writing code is itself a signal of experience.

---

## D011 — Real-time pricing via Azure's Retail Prices API, not a hardcoded table
**Decision:** The waste-scanner calculates estimated monthly cost per finding using Azure's
public Retail Prices API at run time, with a conservative flat-rate fallback if a lookup
ever fails.

**Why:** A hardcoded price table goes stale the moment Azure adjusts pricing, undermining
the credibility of the entire savings figure. The live API costs a small amount of added
complexity for a meaningfully more honest number — and the fallback prevents one bad lookup
from breaking the whole weekly report.

---

## D012 — Separate Terraform and Function-deploy pipelines
**Decision:** Infrastructure changes (`terraform.yml`) and Function code changes
(`deploy-function.yml`) run as two separate GitHub Actions workflows, each scoped to its own
file paths.

**Why:** Different blast radius (a bad code deploy breaks a report; a bad `apply` can modify
or destroy billable infrastructure) and different real-world practice (infrastructure
changes go through a plan-then-approve gate; code deploys don't need the same ceremony).
Combining them would either run Terraform on every code tweak or skip infrastructure review
entirely — both wrong.

---

## D013 — OIDC federated credentials scoped narrowly per event type
**Decision:** Two separate federated credentials were created — one trusting only
`push` events on `main`, one trusting only `pull_request` events — rather than one broad
credential trusting the whole repo.

**Why:** Each workflow job only ever needs to authenticate for the specific event that
triggers it. Scoping credentials that tightly means a token minted from an unexpected
context (a fork, a different branch) is refused by Azure outright — least privilege applied
to CI/CD trust itself, not just to Azure RBAC roles.

---

## D014 — One-day offset between scanner and report-builder schedules
**Decision:** The waste-scanner runs Mondays at 8am; the report-builder runs Tuesdays at
9am — a deliberate one-day gap, not arbitrary timing.

**Why:** Azure's native Cost Management export also runs on its own weekly schedule. The
report-builder depends on that export's CSV already being present in blob storage — if both
functions ran on the same day, there'd be a real risk of the report-builder reading storage
before the export has actually landed, producing an incomplete or empty cost summary.
A one-day buffer gives the export reliable time to complete first. This is unrelated to
D009 (independent Resource Graph queries) — that decision is about data dependency between
the two functions; this one is about timing dependency on a third, external process neither
function controls directly.
