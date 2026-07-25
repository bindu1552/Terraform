# Storage Account Terraform Deployment

Terraform to provision the Azure **storage accounts** used by the
the storage service, across the subscriptions the service
deploys into. The resource inventory and subscription/tenant ids are derived
from the service EV2 configuration in `the sample EV2 config`.

## What it creates

| Env  | Subscription (id)                                      | Storage account          | Resource group          |
| ---- | ------------------------------------------------------ | ------------------------ | ----------------------- |
| Test | Test `<TEST_SUBSCRIPTION_ID>` | `tftestblobstore`        | `tfstate-rg`  |
| Test | Test `<TEST_SUBSCRIPTION_ID>` | `tftestautomation`       | `tfstate-rg`    |
| Prod | Prod `<PROD_SUBSCRIPTION_ID>` | `tfprodblobstore`        | `prod-rg`         |

Each storage account is deployed with the hardened settings taken from
`a sample ARM template`:

* `StorageV2`, access tier `Hot`
* `min_tls_version = TLS1_2`, HTTPS only
* Shared key access **disabled** (Azure AD auth only)
* Public blob access **disabled**
* Network default action `Deny` with `AzureServices` bypass
* Public network access **disabled**
* System-assigned managed identity

Optional blob containers per account are supported via the `containers` list in
each `storage_accounts` entry.

## Files

| File           | Purpose                                                        |
| -------------- | -------------------------------------------------------------- |
| `provider.tf`  | Provider + backend configuration (Azure AD auth).              |
| `variables.tf` | Input variable definitions.                                    |
| `main.tf`      | Client config data source and derived locals.                  |
| `storage.tf`   | Resource groups, storage accounts, and containers.             |
| `outputs.tf`   | Useful outputs (ids, names, identity principal ids).           |
| `test.tfvars`  | Test environment values (subscription, tenant, accounts).      |
| `prod.tfvars`  | Prod environment values.                                       |

## Prerequisites

* Terraform >= 1.5.0
* Azure CLI, signed in with an identity holding at least
  *Storage Blob Data Contributor* on the Terraform state storage account and
  rights to create storage accounts in the target subscription.
* A storage account + container for Terraform remote state (see below). The
  backend authenticates with Azure AD (`use_azuread_auth = true`), so no access
  key is required.

By default `create_resource_groups = false`, meaning the resource groups listed
above must already exist. Set it to `true` in the tfvars if Terraform should
create them.

## Usage

```bash
# 1. Sign in and select the target subscription
az login
az account set --subscription <TEST_SUBSCRIPTION_ID>   # Test
export ARM_SUBSCRIPTION_ID=<TEST_SUBSCRIPTION_ID>

# 2. Initialize the backend (Azure AD auth, no key required)
terraform init \
  -backend-config="storage_account_name=<tfstate-account>" \
  -backend-config="container_name=tfstate" \
  -backend-config="key=test.terraform.tfstate"

# 3. Plan / apply
terraform plan  -var-file=test.tfvars
terraform apply -var-file=test.tfvars
```

For production, swap the subscription id and use `prod.tfvars` with a distinct
state key (e.g. `prod.terraform.tfstate`).

## First-time local run (Test subscription)

Step-by-step for running from your workstation against the **Test**
subscription (`<TEST_SUBSCRIPTION_ID>`). PowerShell shown; use
`export` instead of `$env:` on bash.

### 1. Sign in and select the subscription

```powershell
az login
az account set --subscription <TEST_SUBSCRIPTION_ID>
$env:ARM_SUBSCRIPTION_ID = "<TEST_SUBSCRIPTION_ID>"
```

### 2. Change into the terraform folder

```powershell
cd src/terraform
```

### 3. Create the Terraform state storage account (one-time)

Remote state uses an Azure Storage account with Azure AD auth (no access key).
Create it once, then reuse it for every run. Your signed-in identity needs the
**Storage Blob Data Contributor** role on this account.

```powershell
az group create -n tfstate-rg -l westus
az storage account create -g tfstate-rg -n <uniquetfstate> --sku Standard_LRS --encryption-services blob
az storage container create --account-name <uniquetfstate> --name tfstate --auth-mode login
```

> Quick local-only alternative: comment out the `backend "azurerm" {}` block in
> `provider.tf` and skip this step — state is then kept in a local
> `terraform.tfstate` file (fine for experimentation, not for shared use).

### 4. Initialize the backend

```powershell
terraform init `
  -backend-config="storage_account_name=<uniquetfstate>" `
  -backend-config="container_name=tfstate" `
  -backend-config="key=test.terraform.tfstate"
```

### 5. Plan and apply

```powershell
terraform plan  -var-file=test.tfvars
terraform apply -var-file=test.tfvars
```

This creates resource group **`tf_test`** and the storage accounts
**`tftestblobstore`** and **`tftestautomation`** in it.

### Helper script (optional)

`run-local.ps1` wraps the steps above so you don't have to edit `provider.tf`
to switch between remote and local state. It sets the Azure context, runs
`terraform init`, and then the requested action for the chosen environment.

```powershell
# Local state (no state storage account needed) - quick experimentation
./run-local.ps1 -Environment test -LocalState -Action plan
./run-local.ps1 -Environment test -LocalState -Action apply

# Remote azurerm backend
./run-local.ps1 -Environment test -StateStorageAccount <uniquetfstate> -Action apply
```

With `-LocalState` the script writes a `backend_override.tf` (git-ignored) that
overrides the azurerm backend with a local one for that run; remote runs remove
it again. Supported actions: `plan` (default), `apply`, `destroy`.

### Prerequisites / gotchas

* Your identity needs rights to create resource groups and storage accounts in
  the Test subscription (Contributor or the service's Custom Contributor role).
* Storage account names are **globally unique** across Azure — if
  `tftestblobstore` / `tftestautomation` are already taken, `apply` fails;
  change the `name` values in `test.tfvars`.
* Accounts are created with public network access **disabled** and shared-key
  access **disabled** (Azure AD only). Run from an allow-listed network if you
  need to reach the data plane afterwards.

## Adding a storage account

Add an entry to `storage_accounts` in the relevant `*.tfvars`:

```hcl
storage_accounts = {
  my_new_account = {
    name                = "myuniqueaccountname"
    resource_group_name = "my-rg"
    location            = "westus"
    containers          = ["data", "logs"]
  }
}
```
