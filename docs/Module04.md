# AKS and the Pipeline

## What you will build

**In this tutorial, you move the existing Beacon Helm chart from local k3d to Azure Kubernetes Service (AKS). You then create a GitHub Actions pipeline that builds a versioned image, pushes it to GHCR, and deploys it to AKS automatically. Finally, you prove that the cluster is replaceable by deleting it, recreating it from Bicep, and deploying again.**

You will:

1. verify Azure and register the required providers
2. create a subscription budget alert
3. create a small Dev/Test AKS cluster
4. install the existing Beacon chart on AKS
5. install Traefik and obtain a public address
6. configure passwordless GitHub Actions authentication with OIDC
7. build, push, and deploy Beacon from one workflow
8. describe the AKS cluster with Bicep
9. delete and recreate the complete environment
10. remove chargeable resources when each exercise is finished

The completed repository includes:

```text
.github/workflows/build-and-deploy.yml
charts/beacon/
infra/aks.bicep
infra/budget.bicep
README.md
```

This guide is adapted for the Beacon repository from [Module 04: AKS and the Pipeline](https://codex-kubernetes.pages.dev/modules/04/).

> This module creates chargeable Azure resources. The configuration is intentionally small and temporary for a course exercise. A production AKS design normally uses multiple nodes and availability zones, a supported production tier, controlled networking, workload identity, policy enforcement, monitoring, upgrade windows, and stronger availability safeguards.

## Before you start

Complete Module 03 first. You need:

- an Azure subscription where you may create AKS resources
- Azure CLI (`az`)
- `kubectl` and Helm 4
- GitHub CLI (`gh`)
- a GitHub token with only `read:packages` for the GHCR pull Secret
- the Beacon Helm chart in `charts/beacon/`

Run all commands from the repository root.

### Step 1: Verify the Azure subscription

Check the active subscription:

```bash
az account show \
  --query name \
  --output tsv
```

If the wrong subscription is active, sign in and select the correct one:

```bash
az login
```

In a browserless environment, use:

```bash
az login --use-device-code
```

Always check the subscription again before creating or deleting resources.

### Step 2: Register the Azure providers

AKS requires the Container Service and Compute providers:

```bash
az provider register \
  --namespace Microsoft.ContainerService \
  --wait

az provider register \
  --namespace Microsoft.Compute \
  --wait
```

Verify both:

```bash
az provider show \
  --namespace Microsoft.ContainerService \
  --query registrationState \
  --output tsv

az provider show \
  --namespace Microsoft.Compute \
  --query registrationState \
  --output tsv
```

Both commands should return `Registered`.

### Step 3: Create a budget alert in the Azure Portal

A budget does not stop or delete resources. It sends notifications after recorded spending crosses a threshold, and Azure cost data can be delayed.

In the Azure Portal:

1. Open **Subscriptions** and select your subscription.
2. Open **Cost Management > Budgets**.
3. Create a monthly budget named `budget-clo25`.
4. Set the amount to `50` in your billing currency.
5. Add Actual cost alerts at `50%` and `100%`.
6. Add your email address as the recipient.
7. Create the budget.

The budget is a safety alert, not a replacement for deleting unused resources.

### Step 4: Declare the budget with Bicep

Create `infra/budget.bicep`:

```bicep
// A monthly subscription budget with alerts at 50% and 100% of actual cost.
targetScope = 'subscription'

@description('Where the alerts go.')
param email string

@description('The monthly amount in the subscription billing currency.')
param amount int = 50

@description('The first day of the current month.')
param startDate string = utcNow('yyyy-MM-01')

resource budget 'Microsoft.Consumption/budgets@2024-08-01' = {
  name: 'budget-clo25'
  properties: {
    category: 'Cost'
    amount: amount
    timeGrain: 'Monthly'
    timePeriod: {
      startDate: startDate
    }
    notifications: {
      actual_GreaterThan_50_Percent: {
        enabled: true
        operator: 'GreaterThan'
        threshold: 50
        thresholdType: 'Actual'
        contactEmails: [
          email
        ]
      }
      actual_GreaterThan_100_Percent: {
        enabled: true
        operator: 'GreaterThan'
        threshold: 100
        thresholdType: 'Actual'
        contactEmails: [
          email
        ]
      }
    }
  }
}
```

Preview the subscription deployment with your own email address:

```bash
az deployment sub what-if \
  --location westeurope \
  --template-file infra/budget.bicep \
  --parameters email="name@example.com"
```

Because the Portal budget already exists with the same name, the preview may show a modification rather than a second budget.

Deploy it:

```bash
az deployment sub create \
  --location westeurope \
  --template-file infra/budget.bicep \
  --parameters email="name@example.com"
```

Verify that only one budget exists:

```bash
az consumption budget list \
  --query "[].{name:name, amount:amount, grain:timeGrain}" \
  --output table
```

### Step 5: Verify GitHub CLI access

```bash
gh auth status
```

If necessary, authenticate:

```bash
gh auth login
```

The later steps use `gh` to configure repository variables and inspect workflow runs.

### Step 6: Prepare the GHCR read token

Create or reuse a short-lived classic GitHub token that has only `read:packages`. Do not paste it into documentation, commit it, or pass it as a literal command-line value.

The module prompts for it silently when creating the Kubernetes pull Secret.

## Lab 1: Create a small AKS cluster in the Portal

The first cluster is created in the Portal so you can see the choices AKS requires. Lab 4 describes the same cluster in Bicep.

### Step 1: Configure the basics

Open **Create Kubernetes cluster** in the Azure Portal and configure:

| Setting | Course value |
|---|---|
| Resource group | `rg-clo25-<name>` |
| Preset | Dev/Test |
| Cluster name | `aks-clo25-<name>` |
| Region | West Europe |
| Fleet Manager | None |
| Availability zones | None |
| Pricing tier | Free |
| Long-term support | Disabled |
| Kubernetes version | Latest available `1.36.x` |
| Automatic upgrade | Disabled for this short exercise |
| Authentication | Local accounts with Kubernetes RBAC |

Replace `<name>` with a short identifier that makes the resource names unique.

These settings minimize the cost of a disposable learning cluster. They are not a production baseline.

### Step 2: Configure the node pool

Use one small Linux node:

| Setting | Course value |
|---|---|
| Node pool name | `nodepool1` |
| Mode | System |
| Node count | 1 |
| VM size | `Standard_D2as_v7` |
| OS disk size | 32 GiB |
| Autoscaling | Disabled |

Avoid B-series VMs as the cluster's only node pool. The selected size provides 2 vCPUs and 8 GiB for this exercise.

For production, use a resilient system pool, multiple nodes, zones where supported, autoscaling or node auto-provisioning, and workload-appropriate VM families.

### Step 3: Configure monitoring

Disable optional monitoring integrations for this short-lived cost exercise unless your course explicitly requires them. In production, enable appropriate metrics, logs, control-plane diagnostics, and alerting.

### Step 4: Validate and create the cluster

Select **Review + create**, wait for validation, and create the cluster.

Provisioning usually takes several minutes. After the deployment succeeds, open the resource and confirm:

- the cluster is in West Europe
- the Free tier is selected
- one node is running
- the Kubernetes version is `1.36.x`

### Step 5: Connect kubectl to AKS

Save the resource names:

```bash
MY_NAME="name"
RG="rg-clo25-$MY_NAME"
AKS="aks-clo25-$MY_NAME"
```

Replace `name` with the identifier used in the Portal.

Download the cluster credentials:

```bash
az aks get-credentials \
  --resource-group "$RG" \
  --name "$AKS"
```

Inspect the available contexts:

```bash
kubectl config get-contexts
kubectl config current-context
```

The current context should be the AKS cluster. Verify its node:

```bash
kubectl get nodes
```

One node should report `Ready`.

## Lab 2: Install the same chart on AKS

The repository chart stays unchanged. The new cluster is missing the Secrets and ingress controller that existed locally.

### Step 1: Install the Beacon chart

```bash
helm upgrade --install beacon ./charts/beacon
```

Wait briefly, then inspect the Pods:

```bash
kubectl get pods
```

The Pods should initially show `ErrImagePull` or `ImagePullBackOff` because `ghcr-secret` does not exist in the new cluster.

Inspect one Pod:

```bash
kubectl describe pod POD_NAME
```

Look for `FailedToRetrieveImagePullSecret` or an unauthorized GHCR response.

### Step 2: Create the Secrets

Read the GitHub token silently:

```bash
printf 'GitHub token: '
read -rs GHCR_TOKEN
echo
```

Create the pull Secret with your GitHub username:

```bash
kubectl create secret docker-registry ghcr-secret \
  --docker-server=ghcr.io \
  --docker-username=your-github-username \
  --docker-password="$GHCR_TOKEN"

unset GHCR_TOKEN
```

Read and create the application Secret without exposing its value:

```bash
printf 'Beacon API key: '
read -rs BEACON_API_KEY
echo

kubectl create secret generic beacon-secret \
  --from-literal=BEACON_API_KEY="$BEACON_API_KEY"

unset BEACON_API_KEY
```

Restart the Deployment so the Pods retry immediately:

```bash
kubectl rollout restart deployment beacon
kubectl rollout status deployment beacon
```

### Step 3: Confirm that no ingress controller exists

```bash
kubectl get ingressclass
kubectl get ingress
```

The Beacon Ingress requests the `traefik` class, but a new AKS cluster does not contain Traefik. Its `ADDRESS` therefore remains empty.

### Step 4: Install Traefik

Add and update the official chart repository:

```bash
helm repo add traefik https://traefik.github.io/charts
helm repo update traefik
```

Install the pinned course version in its own namespace:

```bash
helm install traefik traefik/traefik \
  --namespace traefik \
  --create-namespace \
  --version 41.6.1
```

Verify the ingress class:

```bash
kubectl get ingressclass
```

The `traefik` class should now exist.

### Step 5: Obtain the public address

Watch the Traefik LoadBalancer Service:

```bash
kubectl get service traefik \
  --namespace traefik \
  --watch
```

Wait until `EXTERNAL-IP` contains an address, then stop the watch with `Ctrl+C`.

Save the address:

```bash
IP=$(kubectl get service traefik \
  --namespace traefik \
  --output jsonpath='{.status.loadBalancer.ingress[0].ip}')

echo "$IP"
```

Call Beacon over the internet:

```bash
curl "http://$IP/info"
```

If Traefik returns 404, confirm that `ingressHost` is empty in `charts/beacon/values.yaml`:

```yaml
ingressHost: ""
```

Then upgrade the release:

```bash
helm upgrade --install beacon ./charts/beacon
```

The same chart now runs locally and on AKS. Only cluster state differed: AKS needed new Secrets, an ingress controller, and a cloud LoadBalancer address.

## Lab 3: Deploy automatically from GitHub Actions

The workflow will build a commit-tagged image, push it to GHCR, authenticate to Azure with OIDC, connect to AKS, and upgrade the Helm release.

### Step 1: Find or create the pipeline identity

Use a consistent display name:

```bash
IDENTITY_NAME="gh-clo25-$MY_NAME"
```

Check for an existing app registration:

```bash
APP_ID=$(az ad app list \
  --display-name "$IDENTITY_NAME" \
  --query "[0].appId" \
  --output tsv)

echo "$APP_ID"
```

If the result is empty and your account is allowed to create identities:

```bash
APP_ID=$(az ad app create \
  --display-name "$IDENTITY_NAME" \
  --query appId \
  --output tsv)

az ad sp create \
  --id "$APP_ID" \
  --output none
```

Get the service principal object ID and subscription ID:

```bash
SP_OBJECT_ID=$(az ad sp show \
  --id "$APP_ID" \
  --query id \
  --output tsv)

SUB_ID=$(az account show \
  --query id \
  --output tsv)
```

These are identifiers, not passwords. Do not print them unnecessarily in shared logs.

### Step 2: Assign the minimum Azure role

Give the pipeline permission to fetch AKS user credentials only within this resource group:

```bash
az role assignment create \
  --assignee-object-id "$SP_OBJECT_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "Azure Kubernetes Service Cluster User Role" \
  --scope "/subscriptions/$SUB_ID/resourceGroups/$RG"
```

This assignment has three parts:

| Part | Value |
|---|---|
| Who | The pipeline service principal |
| What | Azure Kubernetes Service Cluster User Role |
| Where | The course resource group |

The role assignment is deleted with the resource group. The Entra application itself survives because it is tenant-scoped.

> On Windows Git Bash, run `export MSYS_NO_PATHCONV=1` before commands containing `/subscriptions/...` if path conversion interferes.

### Step 3: Trust only this repository's main branch

Ask GitHub for the repository-specific OIDC subject prefix:

```bash
SUBJECT="$(gh api \
  repos/{owner}/{repo}/actions/oidc/customization/sub \
  --jq .sub_claim_prefix):ref:refs/heads/main"

echo "$SUBJECT"
```

List existing federated credentials:

```bash
az ad app federated-credential list \
  --id "$APP_ID" \
  --query "[].subject" \
  --output tsv
```

If the exact subject is not present, create a temporary definition outside the repository working tree:

```bash
CREDENTIAL_FILE=$(mktemp)
```

Create the file with an editor using this JSON, replacing the subject with the value printed above:

```json
{
  "name": "clo25-kubernetes",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "REPLACE_WITH_THE_SUBJECT_VALUE",
  "audiences": ["api://AzureADTokenExchange"]
}
```

Create the credential and then remove the temporary file:

```bash
az ad app federated-credential create \
  --id "$APP_ID" \
  --parameters "$CREDENTIAL_FILE"

rm "$CREDENTIAL_FILE"
```

The federated credential permits only the configured repository and `main` branch to request an Azure token for this identity.

### Step 4: Configure repository variables

Store the public identifiers as GitHub Actions variables:

```bash
printf '%s' "$APP_ID" | gh variable set AZURE_CLIENT_ID

az account show \
  --query tenantId \
  --output tsv | gh variable set AZURE_TENANT_ID

printf '%s' "$SUB_ID" | gh variable set AZURE_SUBSCRIPTION_ID

gh variable list
```

OIDC avoids a long-lived Azure password in GitHub. The workflow receives a short-lived token after GitHub proves the repository and branch identity.

### Step 5: Create the combined workflow

Use `.github/workflows/build-and-deploy.yml`:

```yaml
name: Build and Deploy

on:
  workflow_dispatch:
  push:
    branches:
      - main
    paths-ignore:
      - "**.md"
      - "docs/**"

permissions:
  contents: read
  packages: write

env:
  RESOURCE_GROUP: rg-clo25-name
  CLUSTER: aks-clo25-name

jobs:
  build-and-push:
    runs-on: ubuntu-24.04
    concurrency:
      group: build-${{ github.ref }}
      cancel-in-progress: true
    steps:
      - name: Check Out the Code
        uses: actions/checkout@v7

      - name: Sign In to the Registry
        uses: docker/login-action@v4
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Set Up QEMU
        uses: docker/setup-qemu-action@v4

      - name: Set Up Buildx
        uses: docker/setup-buildx-action@v4

      - name: Build and Push the Image
        run: |
          owner=$(echo "${{ github.repository_owner }}" | tr 'A-Z' 'a-z')
          image="ghcr.io/$owner/beacon:${GITHUB_SHA::7}"
          docker buildx build \
            --file src/Beacon.Api/Dockerfile \
            --platform linux/amd64,linux/arm64 \
            --tag "$image" \
            --push \
            .

  deploy:
    needs: build-and-push
    runs-on: ubuntu-24.04
    concurrency:
      group: deploy-${{ github.ref }}
      cancel-in-progress: false
    permissions:
      contents: read
      id-token: write
    steps:
      - name: Check Out the Code
        uses: actions/checkout@v7

      - name: Sign In to Azure
        uses: azure/login@v3
        with:
          client-id: ${{ vars.AZURE_CLIENT_ID }}
          tenant-id: ${{ vars.AZURE_TENANT_ID }}
          subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}

      - name: Connect to the Cluster
        run: |
          az aks get-credentials \
            --resource-group "$RESOURCE_GROUP" \
            --name "$CLUSTER"

      - name: Set Up Helm 4
        uses: azure/setup-helm@v5
        with:
          version: v4.3.0

      - name: Deploy with Helm
        run: |
          helm upgrade --install beacon ./charts/beacon \
            --set imageTag="${GITHUB_SHA::7}" \
            --wait \
            --timeout 5m
```

Replace the resource group and cluster values with your names.

Important behavior:

- a newer build may cancel an older build
- deployments do not cancel each other midway
- deployment begins only after the image is pushed
- only the deploy job receives `id-token: write`
- `--set imageTag` deploys the image created from the same commit
- `--wait` makes the job fail if the rollout does not become ready

### Step 6: Push and watch the workflow

```bash
git add .github/workflows/build-and-deploy.yml infra
git commit -m "Deploy to AKS on every push"
git push
```

Find and watch the newest run:

```bash
sleep 10

RUN_ID=$(gh run list \
  --workflow build-and-deploy.yml \
  --limit 1 \
  --json databaseId \
  --jq '.[0].databaseId')

gh run watch "$RUN_ID"
```

Both `build-and-push` and `deploy` should finish successfully.

Verify the public application:

```bash
curl "http://$IP/"
```

### Step 7: Prove that a push performs the deployment

Change the version returned by `/` in `src/Beacon.Api/Program.cs`, commit it, and push:

```bash
git add src/Beacon.Api/Program.cs
git commit -m "Release version 5"
git push
```

Do not run Helm manually. Wait for the workflow, then call the application:

```bash
curl "http://$IP/"
```

The new version should be running. This proves that one push builds, publishes, and rolls out the application.

Add a link to the successful run in `README.md`, then commit the documentation. Markdown-only changes are ignored by the workflow.

### Step 8: Delete the chargeable environment

Check the subscription and resource group name:

```bash
az account show --query name --output tsv
echo "$RG"
```

Delete the entire resource group:

```bash
az group delete \
  --name "$RG" \
  --yes \
  --no-wait
```

Poll until deletion is complete:

```bash
az group exists --name "$RG"
```

Keep checking until the command returns:

```text
false
```

Switch kubectl back to the local cluster:

```bash
kubectl config use-context k3d-clo25
```

## Lab 4: Recreate the AKS environment from Bicep

The Azure environment is disposable. The source-controlled Bicep and Helm chart are the durable solution.

### Step 1: Declare the AKS cluster

Create `infra/aks.bicep`:

```bicep
// One AKS cluster with a single small node for the course exercise.
param name string

param location string = resourceGroup().location

@description('2 vCPUs and 8 GiB for the temporary Dev/Test cluster.')
param nodeVmSize string = 'Standard_D2as_v7'

resource aks 'Microsoft.ContainerService/managedClusters@2026-05-01' = {
  name: name
  location: location
  sku: {
    name: 'Base'
    tier: 'Free'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    kubernetesVersion: '1.36'
    dnsPrefix: name
    agentPoolProfiles: [
      {
        name: 'nodepool1'
        mode: 'System'
        osType: 'Linux'
        count: 1
        vmSize: nodeVmSize
        osDiskSizeGB: 32
      }
    ]
  }
}

output provisioningState string = aks.properties.provisioningState
```

Save the names and recreate the resource group:

```bash
MY_NAME="name"
RG="rg-clo25-$MY_NAME"
AKS="aks-clo25-$MY_NAME"

az group create \
  --name "$RG" \
  --location westeurope
```

Preview the deployment:

```bash
az deployment group what-if \
  --resource-group "$RG" \
  --template-file infra/aks.bicep \
  --parameters name="$AKS"
```

The empty resource group should show one AKS managed cluster to create.

Deploy it:

```bash
az deployment group create \
  --resource-group "$RG" \
  --template-file infra/aks.bicep \
  --parameters name="$AKS"
```

After provisioning succeeds, replace the old kubeconfig entry:

```bash
az aks get-credentials \
  --resource-group "$RG" \
  --name "$AKS" \
  --overwrite-existing

kubectl config current-context
kubectl get nodes
```

### Step 2: Restore cluster-local prerequisites

The new cluster contains none of the previous cluster state. Recreate, in order:

1. `ghcr-secret`
2. `beacon-secret`
3. the Traefik release
4. the Beacon release

Use the safe Secret commands from Lab 2, then run:

```bash
helm repo add traefik https://traefik.github.io/charts
helm repo update traefik

helm install traefik traefik/traefik \
  --namespace traefik \
  --create-namespace \
  --version 41.6.1

helm upgrade --install beacon ./charts/beacon
kubectl rollout status deployment beacon
```

### Step 3: Understand the expected pipeline failure

Push another application version. The image build can succeed, but Azure sign-in or cluster connection fails because the old role assignment was deleted with the previous resource group.

Inspect the failed run:

```bash
RUN_ID=$(gh run list \
  --workflow build-and-deploy.yml \
  --limit 1 \
  --json databaseId \
  --jq '.[0].databaseId')

gh run view "$RUN_ID" --log-failed
```

The OIDC identity and federated credential still exist. Only its resource-group-scoped permission is missing.

### Step 4: Restore the role assignment

Resolve the identity IDs again:

```bash
APP_ID=$(az ad app list \
  --display-name "$IDENTITY_NAME" \
  --query "[0].appId" \
  --output tsv)

SP_OBJECT_ID=$(az ad sp show \
  --id "$APP_ID" \
  --query id \
  --output tsv)

SUB_ID=$(az account show \
  --query id \
  --output tsv)
```

Assign the role to the recreated resource group:

```bash
az role assignment create \
  --assignee-object-id "$SP_OBJECT_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "Azure Kubernetes Service Cluster User Role" \
  --scope "/subscriptions/$SUB_ID/resourceGroups/$RG"
```

Allow time for role propagation, then rerun only failed jobs:

```bash
gh run rerun "$RUN_ID" --failed
gh run watch "$RUN_ID"
```

Obtain the new LoadBalancer address and verify Beacon:

```bash
IP=$(kubectl get service traefik \
  --namespace traefik \
  --output jsonpath='{.status.loadBalancer.ingress[0].ip}')

curl "http://$IP/"
```

The address changes because the previous public IP was deleted with the resource group.

### Step 5: Delete the recreated environment

Delete the resource group again:

```bash
az account show --query name --output tsv

az group delete \
  --name "$RG" \
  --yes \
  --no-wait
```

Keep checking until deletion is confirmed:

```bash
az group exists --name "$RG"
```

Do not stop at `true`. Wait until it returns `false`, then select the local context:

```bash
kubectl config use-context k3d-clo25
```

The budget may remain because it has no charge. A push after cluster deletion is expected to build the image but fail to deploy until the AKS environment and role assignment are recreated.

## Verify the completed module

Before the final deletion, verify:

```bash
kubectl get nodes
kubectl get pods
kubectl get ingress
kubectl get service traefik --namespace traefik
helm list
gh run list --workflow build-and-deploy.yml --limit 3
```

Confirm that:

- one AKS node is ready
- all three Beacon Pods are ready
- Traefik has a public LoadBalancer address
- Beacon answers through that address
- the latest application push produced a successful build and deployment
- the workflow uses OIDC and repository variables rather than an Azure password
- the image tag comes from the same commit SHA as the workflow run
- `infra/aks.bicep` can recreate the course cluster
- `infra/budget.bicep` declares the subscription alert
- no real token, kubeconfig, or application Secret is tracked by Git
- after cleanup, `az group exists --name "$RG"` returns `false`

## Production considerations

The course configuration optimizes for learning and low temporary cost. For a production AKS environment, evaluate:

- AKS Automatic or a carefully designed Standard cluster
- Azure CNI Overlay with an appropriate network policy dataplane
- private or restricted API server access
- multiple system nodes and availability zones
- autoscaling or node auto-provisioning
- managed ingress or Gateway API where appropriate
- Microsoft Entra workload identity and Key Vault CSI integration
- Azure Policy and deployment safeguards
- managed metrics, logs, audit logs, and alerts
- controlled Kubernetes and node-image upgrade windows
- PodDisruptionBudgets and topology spread constraints
- ACR with `AcrPull` instead of a stored GHCR pull token when the architecture is fully Azure-based

## Summary

- **The same Helm chart can run locally and on AKS.** The chart did not change; the new cluster needed its own Secrets, ingress controller, and external address.
- **Secrets are cluster state, not source code.** A recreated cluster starts empty, so sensitive values must be supplied again through a secure deployment process.
- **An ingress controller must be installed.** k3d included Traefik, while AKS did not. Installing Traefik created a cloud `LoadBalancer` Service with a public IP address.
- **The pipeline separates build and deployment.** The first job builds and pushes a commit-tagged image; the second deploys exactly that tag with Helm and waits for readiness.
- **OIDC avoids a stored Azure password.** GitHub proves the repository and branch, Azure issues a short-lived token, and repository variables contain only public identifiers.
- **Permissions should use the smallest practical scope.** The pipeline receives the AKS Cluster User role on the course resource group rather than broad subscription-level Contributor access.
- **Bicep makes the cluster reproducible.** The AKS resource, node count, VM size, disk size, tier, and Kubernetes version are declared and reviewable.
- **Identity and permission have different lifetimes.** The Entra identity survives resource-group deletion, while its scoped role assignment is deleted and must be recreated.
- **The cluster is replaceable; the repository is durable.** Bicep recreates infrastructure, Helm recreates workloads, and the pipeline deploys the selected application revision.
- **Unused clusters must be deleted.** A budget only warns about recorded costs. Confirm resource-group deletion until Azure explicitly returns `false`.
