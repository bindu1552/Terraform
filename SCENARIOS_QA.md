# Terraform Hands-On Scenarios — Q&A

A question-and-answer walkthrough of every scenario exercised while building and
operating this storage-account deployment. Use it as a learning reference.

---

## Q1. What are we creating with this Terraform, and for which subscriptions?

**A.** Storage accounts for a sample storage service, driven
by the `storage_accounts` map in each `*.tfvars`. Subscriptions/tenants come
from the service EV2 config (`the sample EV2 config`):

* **Test** — subscription `<TEST_SUBSCRIPTION_ID>`, tenant `<TENANT_ID>`
* **Prod** — subscription `<PROD_SUBSCRIPTION_ID>`, tenant `<TENANT_ID>`

Each account is hardened (StorageV2, TLS1_2, shared-key disabled, public blob
disabled, network Deny + AzureServices bypass, public network disabled,
system-assigned identity).

---

## Q2. Which resources actually get created?

**A.** Resource types:

| Resource | Address | When |
| -------- | ------- | ---- |
| Resource group | `azurerm_resource_group.storage` | only if `create_resource_groups = true` |
| Storage account | `azurerm_storage_account.this` | one per `storage_accounts` entry |
| Blob container | `azurerm_storage_container.this` | one per name in an account's `containers` list |

A `data.azurerm_client_config` and (when not creating RGs) a
`data.azurerm_resource_group` are **read-only** lookups, not created resources.

Current Test tfvars → 2 storage accounts (`tftestblobstore`, `tftestautomation`);
no containers; RG not created (uses existing `tfstate-rg`).

---

## Q3. Why did the storage account name have to change to a `tf`-prefixed name?

**A.** We deliberately avoided the real service account names to keep a safe
sandbox, and storage account names are **globally unique** across Azure, 3–24
lowercase alphanumeric chars. Hence `tftestblobstore`, `tftestautomation`,
`tfprodblobstore`.

---

## Q4. I set `resource_group_name` to an existing RG — why did I have to make `create_resource_groups = false`?

**A.** With `create_resource_groups = true`, Terraform tries to **create** the RG
and fails if it already exists. Because `tfstate-rg` already existed (we created
it for the state account), we set `create_resource_groups = false` so Terraform
**reads** the RG via a data source instead of creating it.

---

## Q5. How do I run this locally for the Test subscription?

**A.**
```powershell
az login
az account set --subscription <TEST_SUBSCRIPTION_ID>
$env:ARM_SUBSCRIPTION_ID = "<TEST_SUBSCRIPTION_ID>"
cd src/terraform
terraform init `
  -backend-config="storage_account_name=<uniquetfstate>" `
  -backend-config="container_name=tfstate" `
  -backend-config="key=test.terraform.tfstate"
terraform plan  -var-file="test.tfvars"
terraform apply -var-file="test.tfvars"
```

---

## Q6. Creating the state storage account failed with `RequestDisallowedByPolicy`. Why?

**A.** The subscription enforces the Azure Policy **"Storage accounts should
prevent shared key access."** New accounts default to allowing shared keys, so
creation was **denied**. Fix: create with shared keys disabled — which is fine
because our backend uses Azure AD auth anyway:

```powershell
az storage account create -g tfstate-rg -n <uniquetfstate> `
  --sku Standard_LRS --allow-shared-key-access false
```

---

## Q7. The `create` command kept erroring on `--min-tls-version TLS1_`. What happened?

**A.** The value was being **truncated** on paste (`TLS1_` instead of `TLS1_2`).
`TLS1_` is invalid. Simplest fix: drop `--min-tls-version` entirely (Azure
defaults new accounts to TLS1_2). Because the create command errored, the
account was never made — which is why the later container-create and
role-assignment failed with "not found".

---

## Q8. With shared keys disabled, how does the container get created / how does auth work?

**A.** Via **Azure AD (Entra ID)**:

* Container create uses `--auth-mode login`.
* The identity needs the **Storage Blob Data Contributor** role on the account.
* Terraform's backend uses `use_azuread_auth = true` (no key).

```powershell
$me = az ad signed-in-user show --query id -o tsv
az role assignment create --assignee $me --role "Storage Blob Data Contributor" `
  --scope ".../storageAccounts/<uniquetfstate>"
# wait ~1-2 min for propagation, then:
az storage container create --account-name <uniquetfstate> --name tfstate --auth-mode login
```

---

## Q9. `terraform init` failed: "argument ... not expected for the selected backend type." Why?

**A.** A leftover **`backend_override.tf`** containing `backend "local" {}` was
overriding the azurerm backend, so the `storage_account_name` / `container_name`
/ `key` args were rejected (local backend doesn't take them). Fix: delete
`backend_override.tf`, then re-run `terraform init` with the backend config.

---

## Q10. `terraform plan` errored: "Too many command line arguments." Why?

**A.** An extra token/hidden character got into the command from copy/paste.
Retype it cleanly: `terraform plan -var-file="test.tfvars"`.

---

## Q11. How do I stop a resource from being destroyed?

**A.** Two layers:

1. **Terraform** — `lifecycle { prevent_destroy = true }` on the resource.
   `destroy` (or any replace) then fails with "Instance cannot be destroyed".
   Must be a literal `true`; to actually destroy later you edit the code first.
2. **Azure** — a `CanNotDelete` **management lock** (enforced everywhere, incl.
   portal/CLI).

---

## Q12. If I add a lock, can I still create new resources in the same RG?

**A.** Depends on **level** and **scope**:

* **CanNotDelete** blocks delete only — you can still create/modify. **ReadOnly**
  blocks create/update too.
* A lock **scoped to a storage account** only affects that account. A lock
  **scoped to the RG** cascades to every resource in it.

So `CanNotDelete` scoped to the account → you can freely create other resources.

---

## Q13. Should the lock be on the storage account or the resource group?

**A.** Lock the **smallest scope** that covers what you want to protect.

* Account scope (`scope = each.value.id`) → protects just that account. Preferred
  for targeted protection.
* RG scope → cascades to all resources in the RG (including the state account if
  it lives there).

---

## Q14. If I add a lock, can Terraform still update the state file?

**A.** Yes, with a **CanNotDelete** lock. Management locks act on the
**control plane** (create/delete of the resource), not the **data plane**
(reading/writing blobs). So state read/write keeps working. Only a **ReadOnly**
lock on the state account/RG would block state writes — avoid that.

We applied a `CanNotDelete` lock (`protect-tfstate`) on the state account and
confirmed subsequent `apply` runs still updated the state blob.

---

## Q15. I added a tag in code (`env=test`) and applied — what happened?

**A.** `apply` showed an in-place update adding the tag:

```
~ tags = {
    + "env"         = "test"
      "creator"     = "tf"
      "environment" = "test"
      "service"     = "the storage service"
  }
Plan: 0 to add, 1 to change, 0 to destroy.
```

Per-account `tags` are merged with `additional_tags` via
`tags = merge(var.additional_tags, each.value.tags)` in `storage.tf`.

---

## Q16. I added a tag manually in the portal, then ran apply. What happened?

**A.** Terraform detected **drift** and **removed** the manual tag, because code
is the source of truth and the tag wasn't in the config:

```
~ tags = {
    - "Env" = "Test1" -> null   # manual tag removed
      ...
  }
```

---

## Q17. Does `terraform plan` detect drift, or only `terraform refresh`?

**A.** **`plan` detects drift.** Every `plan`/`apply` runs an implicit refresh
first (reads real Azure state), then compares code ⟷ state ⟷ reality and reports
the diff. You don't need a separate `terraform refresh`.

* `refresh` — updates state to match reality (state only).
* `plan` — refresh + compare + **report** (read-only, no changes).
* `apply` — refresh + **reconcile reality back to code**.

Terraform reports the exact drifted attribute but does **not** suggest editing
your code — it assumes the code is correct and plans to overwrite reality.

---

## Q18. How do I make an intentional manual change "stick" instead of being reverted?

**A.** **Codify it** — add it to the Terraform code (e.g. the account's `tags`
in `*.tfvars`), then `apply`. We added `Env=Test1` to the `blob` entry; `apply`
then showed `+ "Env" = "Test1"` (kept it), and a follow-up `plan` reported
**`No changes`**. (Alternative: `lifecycle { ignore_changes = [tags] }` to stop
Terraform managing that attribute at all.)

The production rule: **never fix drift by clicking in the portal — fix it in code
via PR and let the pipeline apply it.**

---

## Q19. I re-ran `apply` on an unchanged config. What happened?

**A.** **`Apply complete! Resources: 0 added, 0 changed, 0 destroyed.`** This is
Terraform's **idempotency**: with code = state = Azure, `apply` is a safe no-op.

---

## Q20. I deleted a storage account manually, then ran apply. What happened?

**A.** During refresh Terraform found the account **missing** in Azure, dropped
it from state in-memory, and planned `+ create`:

```
Plan: 1 to add, 0 to change, 0 to destroy.
```

`apply` **recreated** it with all config-defined settings and tags. Proof it was
a brand-new resource: the system-assigned identity **principal id changed**.

> Caveat: recreating means new keys/identity and **empty data** — any blobs in
> the deleted account are gone. Hence `prevent_destroy` + locks in prod.

---

## Q21. The state said the resource existed — why did Terraform still plan to create it?

**A.** Because the **refresh** step queried Azure and found it gone (you had
deleted it). Real Azure is authoritative during refresh, so the stale "exists"
entry in state doesn't win — Terraform reconciles to "must create".

---

## Q22. What happens if I delete the state file (blob) manually?

**A.** Infrastructure keeps running, but Terraform loses its code⟷resource map:

1. Next `plan` shows **no "Refreshing state..." lines** for the resources and
   reports **`Plan: 2 to add`** — it thinks everything must be created.
2. `apply` then **fails**, because the resources already exist:
   ```
   Error: a resource with the ID ".../tftestblobstore" already exists - to be
   managed via Terraform this resource needs to be imported into the State.
   ```
   Nothing is created/modified/deleted — but you're stuck in a "2 to add" loop.
3. `plan`/`apply` alone can **never** self-heal lost state.

---

## Q23. Running `plan` repeatedly after state loss — does it fix itself?

**A.** No. The plan is deterministic off the (empty) state, so it keeps showing
"2 to add". No amount of `plan`/`apply` recovers it — only `import` (or restoring
the deleted blob) does.

---

## Q24. `apply` after state loss errored "already exists". Was anything harmed?

**A.** No. `apply` cannot overwrite/delete existing resources via a *create*
action — Azure just rejects the create (global name uniqueness). Data and
resources are safe; you're simply not recovered yet.

---

## Q25. What did `terraform import` do, and did it change my resources?

**A.** `import` **read** each existing resource's attributes from Azure and
**wrote** them into the (empty) remote state, re-attaching the code address to
the real resource ID:

```
Import prepared! → Refreshing state... → Import successful!
```

It **did not** create, modify, or delete any real infrastructure — it only
rebuilt Terraform's memory (state).

---

## Q26. After the two imports, what did `plan` show?

**A.** *"You can apply this plan to save these new output values to the Terraform
state, **without changing any real infrastructure**."* i.e. **no resource
changes** — code/state/Azure back in sync. The only pending item was populating
empty **output values** (cosmetic). State fully recovered.

---

## Key takeaways

* **State is sacred** — remote backend, blob versioning + soft delete, locking,
  restricted access; never hand-edit/delete it.
* **Code is the source of truth** — drift is reverted; codify intentional changes
  via PR.
* **`plan` detects drift** (implicit refresh); `apply` reconciles.
* **Recover lost state with `import`**, never blind `apply`.
* **Protect resources** with `prevent_destroy` + `CanNotDelete` locks; a
  `CanNotDelete` lock never blocks state writes.
