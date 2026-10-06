# Lab 6: Secrets without passwords

## Goal

Give the Beacon web app a system-assigned managed identity and let it read a secret from Azure Key Vault without storing a password in code, Git, GitHub, app settings or terminal history.

## Prerequisites

You need:

- the Beacon repository with `infra/main.bicep` and `infra/container.bicep`
- `scripts/deploy-infra.sh`, `scripts/deploy-container.sh` and `scripts/provision-all.sh`
- Azure CLI, Bicep CLI, GitHub CLI and Bash or Zsh
- an active Azure login
- Contributor access to the lab resource group
- permission to create app registrations and role assignments only if attempting OIDC

Check the repository and Azure login:

```bash
ls scripts/deploy-infra.sh scripts/deploy-container.sh scripts/provision-all.sh
ls infra/main.bicep infra/container.bicep
az group list --output table
```

On Windows, use Git Bash or WSL. In Git Bash, disable automatic conversion of Azure resource paths:

```bash
export MSYS_NO_PATHCONV=1
```

Use your own name consistently:

- resource group: `rg-clo25-name`
- web app: `app-clo25-name`
- Key Vault: `kv-clo25-name`
- registry: `acrclo25name`

Key Vault names must be globally unique, contain 3–24 letters, numbers or single hyphens, start with a letter and end with a letter or number.

## Steps

### 1. Rebuild and verify the environment

Rebuild both deployment tracks:

```bash
./scripts/provision-all.sh rg-clo25-name acrclo25name
```

If you only need the web app, use:

```bash
./scripts/deploy-infra.sh rg-clo25-name
```

After infrastructure provisioning finishes, start the App Service workflow:

```bash
gh workflow run deploy.yml

sleep 10
RUN_ID=$(gh run list \
  --workflow deploy.yml \
  --limit 1 \
  --json databaseId \
  --jq '.[0].databaseId')

gh run watch "$RUN_ID"
```

Brief explanation:

- `workflow run` starts an existing workflow without creating a new commit.
- `$(...)` captures the newest workflow run ID in `RUN_ID`.
- `gh run watch` waits until that exact run finishes.

Verify the deployed application:

```bash
./scripts/health-check.sh \
  https://app-clo25-name.azurewebsites.net/health
```

Continue when the workflow is green and `/health` returns `200`.

### 2. Give the web app a managed identity

In the web app resource in `infra/main.bicep`, add `identity` directly after `location`:

```bicep
resource app 'Microsoft.Web/sites@2025-03-01' = {
  name: appName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  // Keep the existing kind and properties.
}
```

If the project uses Bicep modules, make this change in `infra/modules/app-service.bicep` instead.

`SystemAssigned` creates an Entra identity whose lifecycle belongs to the web app. It is an identifier, not a stored password.

Preview and deploy:

```bash
./scripts/deploy-infra.sh --what-if rg-clo25-name
./scripts/deploy-infra.sh rg-clo25-name
```

Commit the infrastructure change:

```bash
git add infra
git commit -m "Give the web app a system-assigned identity"
```

Read the generated principal ID:

```bash
APP_PRINCIPAL_ID=$(az webapp identity show \
  --resource-group rg-clo25-name \
  --name app-clo25-name \
  --query principalId \
  --output tsv)

echo "$APP_PRINCIPAL_ID"
```

Save the displayed GUID as verification evidence. Do not hard-code it; a recreated app receives a new identity.

### 3. Get your own Entra object ID

```bash
az ad signed-in-user show \
  --query id \
  --output tsv
```

This object ID identifies the person who will create and verify the secret. It is placed in the parameter file so the Key Vault can grant that identity separate permissions.

### 4. Create the Key Vault Bicep template

Create `infra/security.bicep`:

```bicep
@description('Name of the Key Vault. 3-24 chars, must start with a letter.')
@minLength(3)
@maxLength(24)
param vaultName string

@description('Name of the existing web app that will read secrets.')
param appName string

@description('Your object ID, used to manage the demo secret.')
param deployerObjectId string

@description('Name of the secret in the vault.')
param secretName string = 'demo-secret'

@description('Secret value. Never put this in the parameter file.')
@secure()
param secretValue string

@description('Region. Defaults to the resource group location.')
param location string = resourceGroup().location

var secretsRead = [ 'get', 'list' ]
var secretsWrite = [ 'get', 'list', 'set' ]

resource app 'Microsoft.Web/sites@2025-03-01' existing = {
  name: appName
}

resource vault 'Microsoft.KeyVault/vaults@2026-02-01' = {
  name: vaultName
  location: location
  properties: {
    tenantId: subscription().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: false
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    accessPolicies: [
      {
        tenantId: subscription().tenantId
        objectId: app.identity.principalId
        permissions: {
          secrets: secretsRead
        }
      }
      {
        tenantId: subscription().tenantId
        objectId: deployerObjectId
        permissions: {
          secrets: secretsWrite
        }
      }
    ]
  }
}

resource secret 'Microsoft.KeyVault/vaults/secrets@2026-02-01' = {
  parent: vault
  name: secretName
  properties: {
    value: secretValue
  }
}

output vaultUri string = vault.properties.vaultUri
output secretUri string = secret.properties.secretUri
```

Brief code explanation:

- `@secure()` prevents the secret from appearing as plain text in deployment history.
- `existing` reads the web app and its identity without recreating the app.
- The app receives only `get` and `list`; the deployer also receives `set`.
- Different permissions for different identities demonstrate least privilege.
- `enableRbacAuthorization: false` deliberately selects access policies because Contributor can configure them without permission to create role assignments.
- Soft delete retains a deleted vault for seven days, which protects data but temporarily reserves the vault name.
- The unversioned `secretUri` always points to the latest secret version, allowing rotation without changing the reference.

We choose enableRbacAuthorization: false because they work with Contributor. This lab uses Key Vault access policies instead of RBAC.
Access policies can be configured with Contributor permission, while RBAC requires permission to create role assignments.
RBAC is Microsoft’s recommended approach today, but access policies are simpler and sufficient for this lab.

### 5. Create the parameter file without a secret

Create `infra/security.bicepparam`:

```bicep
using './security.bicep'

param vaultName = 'kv-clo25-name'
param appName = 'app-clo25-name'
param deployerObjectId = 'your-object-id-from-step-3'

param secretValue = readEnvironmentVariable('SECRET_VALUE')
```

`readEnvironmentVariable` records where the value comes from, not the value itself. The parameter file is therefore safe to commit. If `SECRET_VALUE` is missing, deployment stops with `BCP427` instead of creating an empty secret.

### 6. Enter the secret without terminal-history exposure

Use a disposable test value:

```bash
printf 'Secret: '
read -rs SECRET_VALUE
echo
export SECRET_VALUE
```

Check only the value’s length:

```bash
echo ${#SECRET_VALUE}
```

Brief explanation:

- `read -s` hides keyboard input.
- `-r` treats backslashes literally.
- `export` makes the variable visible to Azure CLI and Bicep.
- `${#SECRET_VALUE}` reveals the length, not the secret.

Do not pass `secretValue='...'` on the command line. That would store the value in shell history.

### 7. Validate, preview and deploy the Key Vault

Build the template and remove the generated JSON:

```bash
az bicep build --file infra/security.bicep
rm -f infra/security.json
```

Preview the deployment:

```bash
az deployment group what-if \
  --resource-group rg-clo25-name \
  --template-file infra/security.bicep \
  --parameters infra/security.bicepparam
```

Expected resource-level changes:

- `+` for the Key Vault and secret
- `*` for unrelated resources
- no deletions
- the secret value displayed as `*******`

Deploy:

```bash
az deployment group create \
  --name security-first \
  --resource-group rg-clo25-name \
  --template-file infra/security.bicep \
  --parameters infra/security.bicepparam \
  --query properties.outputs \
  --output json
```

Commit the template and parameter file:

```bash
git add infra/security.bicep infra/security.bicepparam
git commit -m "Add Key Vault with access policies and a managed identity"
```

### 8. Verify least-privilege access

Read the test secret as yourself:

```bash
az keyvault secret show \
  --vault-name kv-clo25-name \
  --name demo-secret \
  --query value \
  --output tsv
```

Inspect both policies:

```bash
az keyvault show \
  --resource-group rg-clo25-name \
  --name kv-clo25-name \
  --query "properties.accessPolicies[].{id:objectId, secrets:permissions.secrets}" \
  --output json
```

Expected permission split:

| Identity | Permissions | Reason |
|---|---|---|
| Web app | `get`, `list` | The application only reads secrets |
| Deployer | `get`, `list`, `set` | A person must create and rotate the value |

Confirm that the read-only policy’s object ID matches `$APP_PRINCIPAL_ID`.

### 9. Give App Service a Key Vault reference

Read the secret URI from the deployment output:

```bash
SECRET_URI=$(az deployment group show \
  --resource-group rg-clo25-name \
  --name security-first \
  --query properties.outputs.secretUri.value \
  --output tsv)

echo "$SECRET_URI"
```

Set a Key Vault reference rather than a value:

```bash
az webapp config appsettings set \
  --resource-group rg-clo25-name \
  --name app-clo25-name \
  --settings "MY_SECRET=@Microsoft.KeyVault(SecretUri=$SECRET_URI)" \
  --output none
```

Verify that the setting contains only the reference:

```bash
az webapp config appsettings list \
  --resource-group rg-clo25-name \
  --name app-clo25-name \
  --query "[?name=='MY_SECRET'].value" \
  --output tsv
```

App Service uses the managed identity to resolve this reference when the app starts. Application code reads `MY_SECRET` like an ordinary environment variable and does not need Key Vault-specific logic.

Check that the platform resolved the reference:

```bash
APP=$(az webapp show \
  --resource-group rg-clo25-name \
  --name app-clo25-name \
  --query id \
  --output tsv)

REFS="https://management.azure.com$APP/config/configreferences"

az rest \
  --method get \
  --url "$REFS/appsettings?api-version=2022-03-01" \
  --query "value[].{name:name, status:properties.status}" \
  --output table
```

Expected result:

```text
Name       Status
---------  --------
MY_SECRET  Resolved
```

Finally, confirm that the app still responds:

```bash
./scripts/health-check.sh \
  https://app-clo25-name.azurewebsites.net/health
```

### 10. Attempt passwordless pipeline authentication with OIDC

This part requires permission to create an app registration and assign Contributor on the resource group. If either action is denied, record the exact failed command and error, then continue to Step 11.

The intended OIDC design is:

1. Create an Entra application and service principal named `gh-clo25-name`.
2. Assign Contributor only on `rg-clo25-name`, not the subscription.
3. Create a federated credential whose subject is tied to this repository and `main` branch.
4. Store client, tenant and subscription IDs as GitHub variables, not secrets.
5. Grant workflows `id-token: write` and `contents: read`.
6. Replace `creds: ${{ secrets.AZURE_CREDENTIALS }}` with ID-based Azure login.

The relevant workflow configuration is:

```yaml
permissions:
  id-token: write
  contents: read
```

```yaml
- name: Sign in to Azure
  uses: azure/login@v3
  with:
    client-id: ${{ vars.AZURE_CLIENT_ID }}
    tenant-id: ${{ vars.AZURE_TENANT_ID }}
    subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}
```

Brief explanation:

- `id-token: write` lets the workflow request a short-lived OIDC token.
- `contents: read` preserves the permission needed by `actions/checkout`.
- The three IDs identify resources but are not passwords, so GitHub variables are sufficient.
- The federated credential restricts use of the identity to the configured repository and branch.
- OIDC replaces a stored client secret with a short-lived token issued for each workflow run.

Update all Azure login steps in both `.github/workflows/deploy.yml` and `.github/workflows/deploy-container.yml`. Confirm that no old login remains:

```bash
grep -n "AZURE_CREDENTIALS" .github/workflows/*.yml
```

No output is expected.

> **Warning:** Keep `AZURE_CREDENTIALS` until OIDC has succeeded after a full resource-group teardown and rebuild. A successful push against an existing resource group is not sufficient proof because the role assignment disappears with the group.

### 11. Document the permission barrier if OIDC is blocked

OIDC implementation is optional when tenant permissions prevent it. The VG requirement is still reachable if the security design and limitation are explained accurately.

Record which barrier occurred:

- app registration creation failed: you may not create Entra applications
- role assignment failed with `AuthorizationFailed`: the identity exists but cannot receive permission on the resource group

Then document the intended solution:

> The pipeline currently uses `AZURE_CREDENTIALS`, which contains a service principal password stored as a GitHub secret. OIDC could not be configured because **[exact permission restriction]**. With the required permission, I would create a federated credential restricted to this repository and the `main` branch, then assign Contributor only on the lab resource group. The pipeline would receive a short-lived token per run, so no Azure password would be stored in GitHub.

Also note that the Container App’s registry administrator key remains another stored credential. A managed identity with the `AcrPull` role would replace it.

### 12. Treat AcrPull as an optional, reversible experiment

If role assignment is permitted, the Container App can receive a system-assigned identity and the `AcrPull` role scoped to the registry. In `container.bicep`, registry authentication would change from username/password to:

```bicep
identity: {
  type: 'SystemAssigned'
}

// Inside configuration.registries
registries: [
  {
    server: acr.properties.loginServer
    identity: 'system'
  }
]
```

The password secret and `acr.listCredentials()` usage can then be removed. This is stronger than a registry administrator password because the identity receives only image-pull permission.

Revert this experiment before teardown unless the role can be recreated automatically. The registry and its role assignment disappear with the resource group; leaving the template dependent on `AcrPull` can break the required container deployment after the next rebuild.

## Inputs required for VG

Add a security section to `TUTORIAL.md` using these six headings. Under each heading, include both the design and the evidence you observed.

### 1. Where my secrets are and what they are

Record:

- the Key Vault secret’s purpose, without revealing its value
- whether `AZURE_CREDENTIALS` still exists
- whether the registry administrator key is still used
- confirmation that no real secret is committed to Git

### 2. How secrets are managed

Record:

- `read -rs` kept the value off the screen and command history
- `readEnvironmentVariable` kept it out of the parameter file
- `@secure()` kept it out of deployment history
- `MY_SECRET` contains a Key Vault reference rather than the value
- application code reads an environment variable and remains unaware of Key Vault
- the configuration-reference status was `Resolved`

### 3. Permission model and least privilege

Record:

- why access policies were chosen instead of RBAC
- the web app identity receives only `get` and `list`
- the deployer receives `get`, `list` and `set`
- why Contributor or AcrPull is scoped to one resource group or registry instead of the subscription
- RBAC as the preferred alternative when role-assignment permission is available

### 4. Pipeline authentication

Record one of these outcomes:

- **OIDC completed:** federated identity, repository/branch restriction, GitHub variables, successful OIDC login evidence and the plan for deleting `AZURE_CREDENTIALS` only after a teardown test
- **OIDC blocked:** exact command, exact permission error, what the restriction blocks and the federated design that would replace the stored password

### 5. Remaining limitations and next steps

Record at least these known limitations:

- `MY_SECRET` was set through Azure CLI and is lost when the app is recreated
- declaring a partial `appSettings` list in Bicep can overwrite existing settings
- the next step is to make one template own the complete app-settings collection
- Key Vault soft delete reserves the deleted name for seven days
- `security.bicep` is not currently part of `provision-all.sh`
- any remaining registry password could be replaced with managed identity and `AcrPull`

This section is especially important for VG because it shows conscious trade-offs rather than presenting the solution as perfect.

### 6. Transport security and Infrastructure as Code

Point to the relevant declarations:

- `httpsOnly` in the App Service template redirects or rejects insecure access
- `minTlsVersion` rejects older TLS versions
- `allowInsecure: false` protects the Container Apps ingress
- managed identity and Key Vault policies are declared in Bicep
- any manual configuration is explicitly documented as a deviation

## Verification

The lab is complete when:

- the web app has a system-assigned identity
- `infra/security.bicep` and `infra/security.bicepparam` are committed
- the parameter file contains no secret value
- Key Vault contains separate policies for the app and deployer
- the app has only read permissions
- `MY_SECRET` contains a reference and its status is `Resolved`
- `/health` still returns `200`
- the secret never appeared on a command line
- OIDC either works in both pipelines or its permission barrier and intended solution are documented
- the six VG security headings contain concrete evidence and justified trade-offs

## Cleanup

If the optional `AcrPull` experiment was performed, revert it before deleting the environment so the container track remains reproducible.

Push committed work and wait for any triggered workflows to finish. Then delete the resource group:

```bash
git push

az group delete \
  --name rg-clo25-name \
  --yes \
  --no-wait
```

Check whether deletion is in progress or complete:

```bash
az group show \
  --name rg-clo25-name \
  --query properties.provisioningState \
  --output tsv 2>/dev/null || echo "Gone"
```

Expected result: `Deleting` or `Gone`.

The managed identities and resource-group-scoped role assignments disappear with their resources. An Entra app registration and federated credential survive because they live outside the resource group, but the Contributor assignment must be recreated after the next rebuild.

The manually configured `MY_SECRET` setting does not return when the web app is recreated. Keep this as an explicit limitation in the VG documentation rather than hiding it.
