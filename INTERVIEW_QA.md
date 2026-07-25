# Terraform Interview Questions & Answers

A comprehensive, scenario-driven Q&A covering Terraform fundamentals, state,
backends, modules, drift, import, CI/CD, security, and Azure specifics. Examples
use generic/placeholder values (`<SUBSCRIPTION_ID>`, `<TENANT_ID>`), never real
secrets.

---

## Table of contents

1. [Fundamentals](#1-fundamentals)
2. [State](#2-state)
3. [Backends & remote state](#3-backends--remote-state)
4. [State locking](#4-state-locking)
5. [Variables, outputs & locals](#5-variables-outputs--locals)
6. [Resources, meta-arguments & lifecycle](#6-resources-meta-arguments--lifecycle)
7. [Providers & versioning](#7-providers--versioning)
8. [Modules](#8-modules)
9. [Provisioners & data sources](#9-provisioners--data-sources)
10. [Functions & expressions](#10-functions--expressions)
11. [Workspaces & environments](#11-workspaces--environments)
12. [Drift detection](#12-drift-detection)
13. [Import & state manipulation](#13-import--state-manipulation)
14. [CI/CD](#14-cicd)
15. [Security & secrets](#15-security--secrets)
16. [Azure-specific](#16-azure-specific)
17. [Scenario / troubleshooting](#17-scenario--troubleshooting)
18. [Rapid-fire one-liners](#18-rapid-fire-one-liners)

---

## 1. Fundamentals

**Q1. What is Terraform and what problem does it solve?**
Terraform is an open-source Infrastructure-as-Code (IaC) tool by HashiCorp that
lets you define infrastructure declaratively in HCL. You describe the desired
end state; Terraform computes and applies the diff to reach it. It solves manual
provisioning drift, gives repeatable/versioned infra, and supports many
providers (Azure, AWS, GCP, Kubernetes, etc.) through one workflow.

**Q2. Declarative vs imperative — which is Terraform?**
Declarative. You state *what* you want (e.g. "one storage account with these
settings"), not the step-by-step *how*. Terraform's engine figures out the
create/update/delete actions by comparing desired config against current state.

**Q3. Explain the core workflow.**
`write → init → plan → apply` (and `destroy` to tear down).
- `init` downloads providers/modules and configures the backend.
- `plan` shows the execution plan (the diff) without changing anything.
- `apply` executes the plan and updates state.
- `destroy` removes managed resources.

**Q4. What is the difference between `terraform plan` and `terraform apply`?**
`plan` is read-only: it refreshes state, computes the diff, and prints proposed
changes. `apply` actually performs those changes and writes new state. `apply`
without a saved plan file re-runs a plan and asks for approval.

**Q5. What files make up a Terraform configuration?**
`*.tf` (config), `*.tfvars` (variable values), `terraform.tfstate` (state,
usually remote), `.terraform.lock.hcl` (provider dependency lock), and the
`.terraform/` dir (downloaded plugins/modules). Conventionally split into
`main.tf`, `variables.tf`, `outputs.tf`, `provider.tf`.

**Q6. What is HCL?**
HashiCorp Configuration Language — the declarative, JSON-compatible language for
writing Terraform. Supports blocks, arguments, expressions, functions, loops
(`for`, `for_each`, `count`), and conditionals.

**Q7. What is idempotency in Terraform?**
Re-running `apply` with no config or infra changes results in **no changes**
("0 to add, 0 to change, 0 to destroy"). Terraform only acts on the diff between
desired and actual state, so repeated applies are safe.

---

## 2. State

**Q8. What is the Terraform state file and why is it needed?**
State (`terraform.tfstate`) is Terraform's record mapping config resources to
real-world resource IDs, plus cached attribute values and dependency metadata.
It's needed to know what already exists, to compute diffs, to track metadata not
in config, and to improve performance (avoid re-reading everything).

**Q9. What happens if the state file is lost/deleted?**
The real infrastructure is **not** deleted — Terraform just forgets it. With
empty state, `plan` shows everything as "to add", and `apply` fails with
"resource already exists — needs to be imported". Recovery is `terraform import`
(or restoring the state from backend versioning/backup), never a blind apply.

**Q10. Should state be committed to Git?**
No. State can contain secrets (passwords, keys) in plaintext and causes merge
conflicts and race conditions. Use a remote backend (with locking + encryption)
and `.gitignore` the local state files.

**Q11. What is `terraform refresh` and is it still recommended?**
`refresh` reconciles state with real infrastructure (reads current attributes).
The standalone command is deprecated in favor of `terraform apply -refresh-only`
/ `plan -refresh-only`, because a silent refresh could hide changes. Note: `plan`
and `apply` already perform an implicit refresh.

**Q12. What is stored inside the state — is it sensitive?**
Resource IDs, all resource attributes (including some secrets returned by
providers), outputs, and dependency info. Yes, treat state as sensitive; encrypt
at rest and restrict access.

---

## 3. Backends & remote state

**Q13. What is a backend?**
A backend defines where state is stored and how operations run. `local` (default)
stores state on disk; remote backends (azurerm, s3, gcs, Terraform Cloud) store
state centrally, enabling team collaboration, locking, and encryption.

**Q14. Why use a remote backend?**
Shared state for teams, state locking to prevent concurrent corruption,
encryption at rest, durability/backup (versioning), and keeping secrets off
developer laptops.

**Q15. Show a partial azurerm backend and explain "partial configuration".**
```hcl
terraform {
  backend "azurerm" {
    use_azuread_auth = true   # auth via Entra ID, no storage keys
  }
}
```
The account/container/key are *omitted* and supplied at init time:
```bash
terraform init \
  -backend-config="storage_account_name=<acct>" \
  -backend-config="container_name=tfstate" \
  -backend-config="key=test.terraform.tfstate"
```
This is **partial backend configuration** — keeps environment-specific values out
of code so the same config serves multiple environments.

**Q16. How do you separate state per environment?**
Use a different **state key** (blob name) per env, e.g.
`test.terraform.tfstate` vs `prod.terraform.tfstate`, or separate
accounts/containers, or Terraform workspaces. Keys are passed via
`-backend-config` at init.

**Q17. What configuration does an azurerm state storage account need?**
A resource group + storage account (StorageV2, usually Standard_LRS/GRS) with a
blob **container** (e.g. `tfstate`). Recommended: **blob versioning + soft
delete** (state recovery), TLS 1.2, and either an access key or Azure AD auth
(`use_azuread_auth = true`) with the identity holding **Storage Blob Data
Contributor**. If shared-key access is disabled by policy, you *must* use Azure
AD auth.

**Q18. How do you read outputs from another state (remote state data source)?**
```hcl
data "terraform_remote_state" "network" {
  backend = "azurerm"
  config = {
    storage_account_name = "<acct>"
    container_name       = "tfstate"
    key                  = "network.terraform.tfstate"
  }
}
# use: data.terraform_remote_state.network.outputs.vnet_id
```

---

## 4. State locking

**Q19. What is state locking and why does it matter?**
Before a write operation, Terraform acquires a lock so two runs can't mutate the
same state simultaneously (which would corrupt it). With azurerm, this is a
**blob lease** on the state blob; with S3 it's a DynamoDB lock table.

**Q20. How do you handle a stuck lock?**
Identify the lock ID from the error, ensure no other run is active, then
`terraform force-unlock <LOCK_ID>`. Use with care — force-unlocking during an
active operation can corrupt state.

**Q21. Does an Azure resource lock (CanNotDelete/ReadOnly) affect state writes?**
- **CanNotDelete** on the state storage account: blocks deletion of the account,
  but data-plane writes to the state blob still work.
- **ReadOnly**: blocks writes too — do **not** put ReadOnly on a state account or
  Terraform can't update state. CanNotDelete is the safe protective lock.

---

## 5. Variables, outputs & locals

**Q22. Difference between `variable`, `local`, and `output`.**
- `variable` — input, set by tfvars/CLI/env/defaults.
- `local` — a named expression computed inside config (DRY, not externally set).
- `output` — values exported after apply (for CLI display or consumption by other
  configs / remote_state).

**Q23. Variable precedence order (lowest → highest)?**
Defaults → environment variables (`TF_VAR_name`) → `terraform.tfvars` →
`*.auto.tfvars` (alphabetical) → `-var-file` → `-var` on CLI. CLI wins.

**Q24. How do you mark a variable or output as sensitive?**
`sensitive = true`. Terraform redacts it in plan/apply output. Note it's still
stored in **plaintext in state**, so protect the backend.

**Q25. What are variable validation blocks?**
```hcl
variable "location" {
  type = string
  validation {
    condition     = contains(["westus", "eastus"], var.location)
    error_message = "location must be westus or eastus."
  }
}
```
They enforce input constraints at plan time.

**Q26. Explain optional object attributes with defaults.**
```hcl
variable "accounts" {
  type = map(object({
    name                      = string
    account_tier              = optional(string, "Standard")
    shared_access_key_enabled = optional(bool, false)
  }))
}
```
`optional(type, default)` lets callers omit hardened defaults while keeping the
type strict.

---

## 6. Resources, meta-arguments & lifecycle

**Q27. `count` vs `for_each` — when to use which?**
- `count` — creates N identical-ish instances indexed by number; good for simple
  duplication or on/off (`count = var.enabled ? 1 : 0`).
- `for_each` — iterates a map/set; each instance keyed by a stable string. Prefer
  `for_each` when items may be added/removed, because removing a middle `count`
  item re-indexes and destroys/recreates others.

**Q28. What does the `lifecycle` block do? Name its arguments.**
- `create_before_destroy` — create replacement before destroying old (avoid
  downtime).
- `prevent_destroy` — hard error if a plan would destroy the resource.
- `ignore_changes` — ignore drift on specified attributes.
- `replace_triggered_by` — force replacement when a referenced thing changes.

**Q29. What is `prevent_destroy` and its limitation?**
`lifecycle { prevent_destroy = true }` makes Terraform error out on any plan that
would destroy (or replace) the resource — a guard against accidental deletion.
Limitation: it must be a **literal** (no variables), and it blocks legitimate
replacements too; you must remove it to intentionally destroy.

**Q30. What is `ignore_changes` used for?**
To tolerate out-of-band changes on specific attributes (e.g. a tag added by
policy, an autoscaled instance count) without Terraform reverting them:
`lifecycle { ignore_changes = [tags["CreatedBy"], public_network_access_enabled] }`.

**Q31. `depends_on` — when is it needed?**
Terraform infers dependencies from references automatically. Use explicit
`depends_on` only for hidden dependencies it can't see (e.g. IAM propagation, or
an ordering not expressed via attribute references).

**Q32. What causes a resource to be replaced (destroy+create)?**
Changing an attribute the provider marks "ForceNew" (immutable), e.g. storage
account name/location. `plan` shows `-/+` and a reason like
"(forces replacement)".

**Q33. What is `-replace` (formerly `taint`)?**
`terraform apply -replace=azurerm_storage_account.this["blob"]` forces recreation
of a specific resource on the next apply. `taint`/`untaint` are the older,
deprecated way to do the same.

---

## 7. Providers & versioning

**Q34. What is a provider?**
A plugin that lets Terraform manage a specific API (azurerm, aws, kubernetes,
random, etc.). Declared in `required_providers` and configured in a `provider`
block.

**Q35. How do you pin provider and Terraform versions? Why?**
```hcl
terraform {
  required_version = ">= 1.7.0"
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "4.76.0" }
  }
}
```
Pinning gives reproducible runs and avoids surprise breaking changes. Version
constraints: `=`, `>=`, `~>` (pessimistic, e.g. `~> 4.0` allows 4.x not 5.0).

**Q36. What is `.terraform.lock.hcl`?**
The dependency lock file recording exact provider versions and hashes. Commit it
so every run/CI uses identical provider builds. Update with
`terraform init -upgrade`.

**Q37. How do you use multiple provider configurations (aliases)?**
```hcl
provider "azurerm" { features {} }                 # default
provider "azurerm" { alias = "prod"; subscription_id = var.prod_sub; features {} }
resource "x" "y" { provider = azurerm.prod }
```
Used to target multiple subscriptions/regions in one config.

---

## 8. Modules

**Q38. What is a module?**
A reusable container of `.tf` files. The **root module** is your working dir;
**child modules** are called via `module` blocks with inputs and outputs. Modules
promote reuse, consistency, and abstraction.

**Q39. How do you call a module and pass values?**
```hcl
module "storage" {
  source  = "./modules/storage"        # or a registry/git source
  version = "1.2.0"                     # for registry sources
  name    = "tfblob"
  tags    = { env = "test" }
}
# consume: module.storage.account_id
```

**Q40. Local vs registry vs git module sources?**
- Local: `./modules/x` — versioned with your repo.
- Registry: `namespace/name/provider` + `version` — public/private registry.
- Git: `git::https://…//subdir?ref=v1.0.0` — pin with `?ref=`.

**Q41. How do you version modules and why?**
Registry modules use the `version` argument; git modules use `?ref=<tag>`.
Pinning ensures reproducible, controlled upgrades rather than pulling `main`.

**Q42. How do child modules expose data?**
Through `output` blocks in the module, accessed as `module.<name>.<output>` in
the caller. Child module state is not directly readable otherwise.

---

## 9. Provisioners & data sources

**Q43. What is a data source?**
A read-only lookup of existing infrastructure or computed data:
```hcl
data "azurerm_client_config" "current" {}
data "azurerm_resource_group" "existing" { name = "my-rg" }
```
Used to reference things Terraform doesn't manage.

**Q44. What are provisioners and why avoid them?**
`local-exec`/`remote-exec` run scripts during create/destroy. They're a
"last resort" — non-idempotent, not tracked in state, and brittle. Prefer native
resources, cloud-init, or configuration-management tools. Use only when no
provider capability exists.

**Q45. What is a `null_resource` / `terraform_data`?**
A resource with no cloud object, used to attach provisioners or trigger actions
on `triggers` changes. `terraform_data` (1.4+) is the built-in replacement for
`null_resource` and needs no external provider.

---

## 10. Functions & expressions

**Q46. Give common built-in functions you use.**
`merge()`, `lookup()`, `coalesce()`, `try()`, `for`/`for_each` expressions,
`toset()`, `tolist()`, `jsonencode()`, `templatefile()`, `cidrsubnet()`,
`format()`, `join()`, `keys()`, `values()`.

**Q47. `try()` vs `can()`?**
`try(expr, fallback)` returns the first expression that succeeds; `can(expr)`
returns a bool indicating whether an expression evaluated without error (often
used inside `validation` conditions).

**Q48. What is a dynamic block?**
Generates repeatable nested blocks from a collection:
```hcl
dynamic "network_rules" {
  for_each = var.rules
  content { ip_rules = network_rules.value.ips }
}
```

**Q49. Conditional expression example?**
`var.env == "prod" ? "GRS" : "LRS"` — ternary for choosing values based on a
condition.

---

## 11. Workspaces & environments

**Q50. What are Terraform workspaces?**
Named, isolated state instances within one backend/config
(`terraform workspace new/select`). `terraform.workspace` gives the current name.
Good for lightweight env separation sharing identical config.

**Q51. Workspaces vs separate state files/dirs — trade-offs?**
Workspaces share the same config and backend (one blob per workspace), which can
be risky if envs must diverge or need different backends. Many teams instead use
**separate directories + tfvars + state keys** per env for clearer isolation and
independent backends. (The CI/CD reference uses per-env tfvars + state keys, not
workspaces.)

**Q52. How do you promote changes across environments?**
Build once, apply many: run `plan`/`apply` per env with that env's
`-var-file` and state key, gated by approvals. Same config, different inputs and
state — no config forking.

---

## 12. Drift detection

**Q53. What is drift?**
When real infrastructure diverges from what state/config says — e.g. someone
manually adds a tag or changes a setting in the portal.

**Q54. Does `terraform plan` detect drift? What about `refresh`?**
Yes — `plan` performs an **implicit refresh** first, so it detects and shows
drift as proposed changes to reconcile back to config. `refresh` (or
`apply -refresh-only`) only updates state to match reality without proposing
config-driven changes. So both "detect" drift, but `plan` also shows how it would
be corrected.

**Q55. Scenario: someone manually added a tag in the portal. What does the next `apply` do?**
`plan` shows Terraform will **remove** the manual tag (config is source of
truth). `apply` reverts it. To keep the change: add it to config, or use
`lifecycle { ignore_changes = [tags["X"]] }` to leave it alone.

**Q56. How do you detect drift continuously in production?**
Scheduled `terraform plan -detailed-exitcode` in CI (exit code 2 = drift), alert
on non-zero, and optionally `apply -refresh-only` to record benign changes.
`ignore_changes` for attributes intentionally managed out-of-band.

**Q57. What does `-detailed-exitcode` return?**
`0` = no changes, `1` = error, `2` = changes present. Lets pipelines distinguish
"nothing to do" from "there is a diff" from "failed".

---

## 13. Import & state manipulation

**Q58. What does `terraform import` do exactly?**
It reads an existing real resource by its ID and records it in **state**, mapped
to a config address — bringing an unmanaged (or state-lost) resource under
management. It writes state to the configured backend; it does **not** create,
modify, or recreate the real resource, and it does **not** write config for you.

**Q59. When the state is deleted, does import recreate the state blob?**
Yes — import writes to the active backend. If the remote state blob was deleted,
importing effectively recreates it containing whatever you import. If the blob
still exists, import updates it in place. You must import each resource address
individually (one command per resource).

**Q60. Scenario: `apply` fails with "resource already exists — needs to be imported". Why and fix?**
State has no record of the resource (state lost/never tracked), so Terraform
tries to *create* something that already exists in Azure → conflict. Fix:
`terraform import '<address>' '<azure-resource-id>'` for each affected resource,
then `plan` should show "No changes".
```bash
terraform import 'azurerm_storage_account.this["blob"]' \
  /subscriptions/<SUBSCRIPTION_ID>/resourceGroups/<rg>/providers/Microsoft.Storage/storageAccounts/<name>
```

**Q61. Terraform 1.5+ import blocks — what are they?**
Declarative import via config, planned/applied like normal:
```hcl
import {
  to = azurerm_storage_account.this["blob"]
  id = "/subscriptions/.../storageAccounts/<name>"
}
```
Runs during `plan`/`apply` (no separate CLI step) and can generate config with
`-generate-config-out`.

**Q62. Other state manipulation commands?**
`terraform state list`, `state show <addr>`, `state mv <src> <dst>` (rename/move,
e.g. into a module), `state rm <addr>` (stop managing without deleting real
resource), `state pull`/`push`. Use carefully — these edit state directly.

**Q63. How do you prove a resource was recreated vs updated in place?**
Look at `plan` (`-/+` = replace, `~` = in-place). After apply, a changed
system-assigned identity **principal_id** (or a new resource GUID/creation time)
proves it was recreated, not merely updated.

---

## 14. CI/CD

**Q64. How do you run Terraform in CI/CD safely?**
Split build (package/validate) from deploy (plan→apply). Use remote state with
locking, a machine identity (OIDC/service principal) not user creds, run
`fmt -check` + `validate` as gates, review `plan` before an approval-gated
`apply`, and pin Terraform/provider versions.

**Q65. What is the typical plan→apply gating pattern?**
Plan stage runs ungated so reviewers can inspect the diff; Apply stage requires a
manual/environment **approval** and runs `apply -auto-approve` on the reviewed
plan. Promote across envs sequentially (test → stage → prod).

**Q66. How do you authenticate Terraform to Azure in a pipeline without secrets?**
**OIDC / workload identity federation** via an ADO/GitHub service connection. The
pipeline mints a short-lived token trusted by an Entra federated credential; no
client secret or storage key is stored. Set `ARM_USE_OIDC=true`, `ARM_CLIENT_ID`,
`ARM_TENANT_ID`, `ARM_SUBSCRIPTION_ID` at runtime.

**Q67. Difference between the pipeline identity and the triggering user?**
The pipeline authenticates as the **service connection's service principal**, not
the user who triggered it. The user's permissions matter only at connection
*creation* time (automatic setup) and for *approvals* — never for the actual
Azure API calls at run time.

**Q68. Should you commit the plan file between stages?**
Yes — best practice is `plan -out=tfplan`, publish it as an artifact, and
`apply tfplan` in the gated stage so you apply exactly what was reviewed. (Note:
plan files can contain sensitive values; treat as artifacts accordingly.)

**Q69. How do you keep per-environment config in CI?**
Per-env `*.tfvars` + per-env backend key passed via `-backend-config`, selected by
a stage parameter (`test`/`prod`). Same config, different inputs and state.

---

## 15. Security & secrets

**Q70. How do you avoid secrets in state/config?**
Don't hardcode secrets; pull from Key Vault via data sources or inject via
pipeline variables/OIDC. Remember outputs/attributes still land in state, so
encrypt and lock down the backend, and mark values `sensitive`.

**Q71. How do you reference Azure Key Vault secrets?**
```hcl
data "azurerm_key_vault_secret" "db" {
  name         = "db-password"
  key_vault_id = data.azurerm_key_vault.kv.id
}
# data.azurerm_key_vault_secret.db.value  (ends up in state — protect it)
```

**Q72. Best practices for least privilege?**
Scope the deploy SP to the minimum roles (e.g. Contributor on a specific RG +
Storage Blob Data Contributor on the state account), one identity per
environment, restrict which pipeline can use each service connection, and prefer
custom roles over broad Owner/Contributor when feasible.

**Q73. How do you protect critical resources from deletion?**
Layered: `lifecycle { prevent_destroy = true }` in Terraform, an Azure
**CanNotDelete** lock on the resource/RG, RBAC restrictions, and backend state
versioning. CanNotDelete (not ReadOnly) is safe for state accounts.

---

## 16. Azure-specific

**Q74. How does the azurerm provider authenticate (options)?**
Azure CLI (`az login`, local dev), Service Principal + client secret/cert,
Managed Identity, and OIDC/workload identity federation (CI). Controlled via
`ARM_*` env vars or provider arguments.

**Q75. What is `use_azuread_auth` on the backend?**
Tells the azurerm backend to authenticate to the state storage account via Entra
ID (RBAC) instead of a storage account key — required when shared-key access is
disabled by policy. The identity needs **Storage Blob Data Contributor**.

**Q76. Scenario: storage create fails with `RequestDisallowedByPolicy` (shared key).**
An Azure Policy denies shared-key access. Fix: set
`shared_access_key_enabled = false` on the account (and `--allow-shared-key-access
false` in any CLI create), and use Azure AD auth for the backend
(`use_azuread_auth = true`).

**Q77. How do you deploy to multiple subscriptions?**
Provider aliases (`provider "azurerm" { alias = "prod"; subscription_id = ... }`)
with `provider = azurerm.prod` on resources, or separate root configs/state per
subscription selected by tfvars — the latter is cleaner for isolation.

**Q78. What role does `azurerm_role_assignment` play for the state account?**
Grants the deploy identity **Storage Blob Data Contributor** on the state
account so Azure AD-authenticated state reads/writes work. Allow 1–2 minutes for
RBAC propagation before the first init.

**Q79. GRS vs LRS vs ZRS for a storage account?**
LRS = 3 copies in one datacenter (cheapest). ZRS = across zones in a region. GRS =
LRS + async replication to a paired region (DR). GZRS = ZRS + geo. Choose by
durability/DR requirements and cost.

---

## 17. Scenario / troubleshooting

**Q80. Scenario: `terraform init` fails "argument not expected for selected backend type".**
Usually a stray/duplicate backend block (e.g. a leftover `backend_override.tf`
forcing `backend "local"`) conflicting with `-backend-config`. Remove the
override / duplicate backend block and re-run `init -reconfigure`.

**Q81. Scenario: two engineers apply at once.**
The remote backend's **lock** (blob lease) makes the second run wait or fail with
a lock error until the first finishes — preventing state corruption. Don't
force-unlock unless you're sure the other run is dead.

**Q82. Scenario: you deleted a storage account manually. What does the next `apply` do?**
`plan` detects the resource is gone (refresh) and shows `+ create`; `apply`
recreates it from config. A new principal_id/creation time confirms it's a fresh
resource, not the old one.

**Q83. Scenario: you want to rename a resource in config without destroying it.**
Use `terraform state mv <old_address> <new_address>` (or a `moved {}` block in
1.1+) so Terraform tracks it as the same object instead of destroy+create.

**Q84. What is a `moved` block?**
```hcl
moved {
  from = azurerm_storage_account.old
  to   = azurerm_storage_account.this["blob"]
}
```
Declaratively records refactors (renames, moving into modules, count→for_each) so
existing resources aren't destroyed.

**Q85. Scenario: `plan` keeps showing a change every run (perpetual diff).**
Often a provider normalizing a value, a computed attribute, or out-of-band
mutation. Fix by aligning config to the provider's canonical form, or
`ignore_changes` on that attribute, or `-refresh-only` to accept the current
value.

**Q86. Scenario: apply partially failed midway. What now?**
Terraform records what succeeded in state. Re-run `plan`/`apply` — it continues
from the current state (created resources are kept, remaining ones retried). Fix
the root cause (quota, perms) first. Avoid manual portal fixes that cause drift.

**Q87. How do you target a single resource?**
`terraform apply -target=azurerm_storage_account.this["blob"]`. Use sparingly —
it can produce a partial/inconsistent state; it's a debugging/recovery tool, not
routine workflow.

**Q88. How do you safely destroy only part of infrastructure?**
`terraform destroy -target=<addr>` for a specific resource, or split into separate
state/configs. Beware dependencies — targeting can leave dangling references.

---

## 18. Rapid-fire one-liners

- **`terraform fmt`** — rewrite files to canonical style; `-check` fails if
  unformatted (good CI gate).
- **`terraform validate`** — checks config syntax/consistency (no cloud calls,
  no backend needed with `-backend=false`).
- **`terraform show`** — human/JSON view of state or a plan file.
- **`terraform graph`** — dependency graph (DOT format).
- **`terraform output`** — print output values (`-json` for machine use).
- **`terraform console`** — REPL to test expressions/functions.
- **`~>` constraint** — pessimistic pin (`~> 4.0` = >=4.0, <5.0).
- **`TF_LOG=DEBUG`** — verbose logging for troubleshooting.
- **`terraform state list`** — enumerate managed resources.
- **`-parallelism=n`** — cap concurrent resource operations (default 10).
- **`-lock-timeout=5m`** — wait for a held state lock instead of failing fast.
- **`terraform init -upgrade`** — refresh providers within version constraints and
  update the lock file.
- **`count.index` / `each.key` / `each.value`** — loop identifiers.
- **`terraform.workspace`** — current workspace name.
- **`nonsensitive()`** — deliberately unmask a sensitive value (use with care).

---

### Interview tips

- Always distinguish **state vs real infrastructure** — most tricky questions
  (lost state, import, drift) hinge on this.
- Emphasize **plan before apply**, **remote state + locking**, and **no secrets
  in code/state**.
- Prefer **`for_each` over `count`**, **pinned versions**, and **module reuse**.
- For CI/CD: **OIDC (no secrets)**, **approval-gated apply**, **build once /
  deploy many**.
