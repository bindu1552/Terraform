# Terraform State, Locking & Drift — Operational Notes

Hands-on notes for this storage-account deployment, covering how the remote
state backend is set up, how to protect resources from deletion, how drift is
detected, and what happens if the state file is lost.

---

## 1. First-time setup: storage account for the backend state file

Terraform needs somewhere to persist its **state file** (the record of what it
manages). We use an Azure Storage account + blob container as the remote
backend, authenticated with **Microsoft Entra ID (Azure AD)** — no access keys.

### 1a. Configuration required on the state storage account

| Setting | Value | Why |
| ------- | ----- | --- |
| SKU / replication | `Standard_LRS` | Cheap; state is small and re-creatable. |
| Kind | `StorageV2` (default) | Standard general-purpose v2. |
| **Shared key access** | **Disabled** (`--allow-shared-key-access false`) | The subscription enforces the Azure Policy *"Storage accounts should prevent shared key access"* — creation is **denied** otherwise. |
| Min TLS version | `TLS1_2` (default) | Security baseline. |
| Blob container | one container, e.g. `tfstate` | Holds the `*.terraform.tfstate` blob. |
| Auth mode | Azure AD (`--auth-mode login`) | No keys; uses your signed-in identity. |
| RBAC role | **Storage Blob Data Contributor** on the account | Required for the identity running Terraform (and for creating the container) since shared keys are off. |
| Blob **versioning + soft delete** | **Enable (recommended)** | Lets you recover the state blob if it is deleted/corrupted (see §4). |
| Resource lock | `CanNotDelete` (optional but recommended) | Protects the account from deletion; does **not** block state read/write. |

### 1b. Commands used (one-time)

```powershell
# Resource group for state
az group create -n tfstate-rg -l westus

# State storage account (shared key OFF to satisfy policy)
az storage account create -g tfstate-rg -n <uniquetfstate> `
  --sku Standard_LRS --allow-shared-key-access false

# Grant yourself data-plane access (Azure AD auth)
$me = az ad signed-in-user show --query id -o tsv
az role assignment create --assignee $me `
  --role "Storage Blob Data Contributor" `
  --scope "/subscriptions/<sub-id>/resourceGroups/tfstate-rg/providers/Microsoft.Storage/storageAccounts/<uniquetfstate>"

# (wait ~1-2 min for role propagation, then)
az storage container create --account-name <uniquetfstate> --name tfstate --auth-mode login

# Optional: protect the state account from deletion
az lock create --name "protect-tfstate" --lock-type CanNotDelete `
  --resource-group tfstate-rg --resource-name <uniquetfstate> `
  --resource-type "Microsoft.Storage/storageAccounts"
```

> The storage account name must be **3–24 chars, lowercase letters + numbers,
> globally unique**.

### 1c. Changes required in the Terraform files

**`provider.tf`** — declare the azurerm backend with Azure AD auth (no key):

```hcl
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "4.76.0"
    }
  }

  backend "azurerm" {
    use_azuread_auth = true      # <-- authenticate to state with Entra ID, no key
  }
}

provider "azurerm" {
  features {}
  storage_use_azuread = true
  subscription_id     = var.subscription_id
  tenant_id           = var.tenant_id
}
```

The account/container/key are **not** hard-coded — they are passed at
`init` time so the same code serves multiple environments:

```powershell
terraform init `
  -backend-config="storage_account_name=<uniquetfstate>" `
  -backend-config="container_name=tfstate" `
  -backend-config="key=test.terraform.tfstate"
```

> Tip: for quick local experimentation you can drop a `backend_override.tf`
> containing `terraform { backend "local" {} }` to store state in a local file
> instead. Remove it to go back to the remote backend.

---

## 2. Prevent accidental deletion — locks & lifecycle

Two independent layers are used; combine them for defence in depth.

### 2a. Terraform-level: `prevent_destroy`

Added to the storage account resource in `storage.tf`:

```hcl
resource "azurerm_storage_account" "this" {
  # ...
  lifecycle {
    ignore_changes  = [public_network_access_enabled]
    prevent_destroy = true          # <-- destroy/replace is blocked
  }
}
```

* `terraform destroy` (or any plan that would delete/replace the resource)
  **fails** with `Instance cannot be destroyed`.
* Value must be a **literal** `true`/`false` — cannot reference a variable.
* To genuinely remove the resource later you must edit the code (set `false` or
  remove the line), then destroy. That friction is intentional.

### 2b. Azure-level: management lock (`CanNotDelete`)

Enforced by Azure regardless of the tool used (portal, CLI, Terraform):

| Lock level | Blocks delete? | Blocks create/update? |
| ---------- | -------------- | --------------------- |
| **CanNotDelete** | ✅ | ❌ (create/modify still allowed) |
| **ReadOnly** | ✅ | ✅ (also blocks writes — avoid on the state account) |

**Scope matters — lock the smallest scope that covers what you want:**

* Lock **on the storage account** (`scope = each.value.id`) → protects only that
  account; other resources in the RG are unaffected. *Preferred for targeted
  protection.*
* Lock **on the resource group** → cascades to **every** resource in the RG
  (existing and future), including the state account if it lives there.

Example (Terraform), toggle-able and scoped to the accounts:

```hcl
resource "azurerm_management_lock" "storage" {
  for_each   = azurerm_storage_account.this
  name       = "no-delete"
  scope      = each.value.id
  lock_level = "CanNotDelete"
  notes      = "Protect service storage from deletion."
}
```

> **Important:** a `CanNotDelete` lock does **not** block data-plane writes, so
> Terraform state read/write on a locked state account still works. Only a
> **ReadOnly** lock would break state writes.

---

## 3. Drift detection — does `plan` detect drift, or only `refresh`?

**Yes, `terraform plan` detects drift.** Drift = when real infrastructure no
longer matches what the state/code expects (e.g. someone edits a tag in the
portal).

How it works — every `plan` and `apply` runs an implicit **refresh** first:

1. **Refresh** — reads the *real* state of each resource from Azure.
2. **Compare** three things: **code** ⟷ **state** ⟷ **actual Azure**.
3. **Report** the diff with symbols: `+` add, `-` remove, `~` change, `-/+`
   replace.

So you do **not** need to run `terraform refresh` separately — `plan` already
includes it and will show the drift.

| Command | Detects drift? | Changes anything? |
| ------- | -------------- | ----------------- |
| `terraform refresh` | Yes (updates state to match reality) | Updates state only |
| `terraform plan` | **Yes** (refresh + compare + report) | No (read-only preview) |
| `terraform apply` | Yes, then **reconciles** reality back to code | Yes |

### What Terraform does with drift

Terraform treats **code as the source of truth** and plans to make reality match
the code. It **reports** the exact attribute but does **not** suggest editing
your code:

* Manual tag/setting added in portal → `apply` **reverts/removes** it.
* Resource manually deleted → `apply` **recreates** it.
* Config changed in code → `apply` **pushes** the change to Azure.

### Observed examples from this project

* Manually added tag `Env=Test1` → `plan` showed `- "Env" = "Test1" -> null`
  and `apply` removed it.
* To **keep** an intentional manual change, codify it (add to `*.tfvars`), then
  `apply` shows `+ "Env" = "Test1"` and a follow-up `plan` reports
  **`No changes`**.
* Manually deleted a storage account → `plan` showed `+ create` and `apply`
  rebuilt it (new managed-identity principal id proved it was a fresh resource).

### Handling drift in production

* Manual portal changes are **discouraged** — everything goes through code + PR.
* CI runs `terraform plan` on every PR and posts the diff.
* A scheduled **drift-detection** job runs `terraform plan -detailed-exitcode`:
  * exit `0` = no drift, `2` = drift detected, `1` = error → alert the team.
* If drift is intentional → codify it via PR. If not → let the next `apply`
  revert it.
* If a field is legitimately managed elsewhere, use
  `lifecycle { ignore_changes = [tags] }` so Terraform stops reconciling it.

---

## 4. What happens if the state file is deleted manually?

**Deleting state ≠ deleting infrastructure.** The real Azure resources keep
running, but Terraform loses its **only** record mapping code ⟷ real resources.

### Behaviour observed

1. Next `plan` has **no "Refreshing state..." lines** for the resources (nothing
   in state to refresh) and reports **`Plan: N to add`** — it thinks everything
   must be created from scratch, even though the resources still exist.
2. Running `apply` then tries to **create resources that already exist** and
   **fails**:

   ```
   Error: a resource with the ID ".../storageAccounts/tftestblobstore" already
   exists - to be managed via Terraform this resource needs to be imported into
   the State.
   ```

   Nothing is created, modified, or deleted — global name uniqueness + the
   existing resource protect you. But you are **not** recovered: every future
   `plan` shows "N to add" and every `apply` fails the same way.
3. `plan`/`apply` **can never self-heal** lost state — they would only try to
   duplicate existing resources.

### Recovery — `terraform import` (not apply)

Re-attach each existing Azure resource to the fresh state:

```powershell
terraform import -var-file="test.tfvars" 'azurerm_storage_account.this["blob"]' `
  "/subscriptions/<sub-id>/resourceGroups/tfstate-rg/providers/Microsoft.Storage/storageAccounts/tftestblobstore"

terraform import -var-file="test.tfvars" 'azurerm_storage_account.this["automation"]' `
  "/subscriptions/<sub-id>/resourceGroups/tfstate-rg/providers/Microsoft.Storage/storageAccounts/tftestautomation"
```

Each import writes the resource back into the remote state blob
(`Import successful!`). Afterwards:

```powershell
terraform plan -var-file="test.tfvars"   # expect: No changes
```

Alternatively, if **blob versioning / soft delete** is enabled on the state
account, restore the deleted state blob instead of re-importing.

### Why prod treats state as sacred

* **Remote backend** (this project uses azurerm) — never keep prod state only on
  a laptop.
* **Enable blob versioning + soft delete** on the state account for recovery.
* **State locking** is automatic with the azurerm backend (you see
  "Acquiring state lock…") — prevents two applies corrupting state at once.
* **Restrict access** and **never hand-edit/delete** the state blob; use
  `terraform state` / `terraform import` commands instead.
* Protect the state account with a `CanNotDelete` lock (data-plane writes still
  work, so state updates are unaffected).
