# Exercise 11: Build an Azure Function and evaluate serverless

## Goal

Create and run the same .NET 10 HTTP-triggered Azure Function locally and in Azure, then provision its infrastructure with Bicep. Use the results to write the VG-level serverless decision for `TUTORIAL.md`.

The assessed VG outcome is not merely a working Function. It is a justified architectural decision based on verified platform support, estimated cost, operational trade-offs, and a clear threshold at which your decision would change.

## Prerequisites

You need:

- basic experience with C#, .NET and a terminal
- .NET 10 SDK
- Azure Functions Core Tools v4
- Azure CLI and Bicep CLI
- an active Azure subscription
- permission to create a resource group, storage account and Function App
- the existing course repository for the Bicep files
- a separate empty folder for the Function sandbox

Check the tools and Azure login:

```bash
dotnet --version
func --version
az bicep version
az account show --output table
```

`dotnet` should report version 10 and `func` should report version 4. Log in if the Azure account command fails:

```bash
az login
```

The examples use these placeholders:

- resource group: `rg-clo25-name`
- storage account: `stclo25name`
- portal app: `func-clo25-name`
- CLI app: `func-clo25-cli-name`
- Bicep app: `func-clo25-bicep-name`

> **Warning:** Replace `name` consistently. Function App and storage account names must be globally unique. Storage account names may contain only lowercase letters and numbers and must be 3–24 characters long.

## Steps

### 1. Create the local Functions project

Work in an empty sandbox folder outside the course repository:

```bash
func init MinFunction --worker-runtime dotnet-isolated
cd MinFunction
```

Brief explanation:

- `func init` creates an Azure Functions project.
- `--worker-runtime dotnet-isolated` selects the isolated .NET worker model required by .NET 10.
- The isolated model runs the function code in a process separate from the Functions host.

Create an anonymous HTTP-triggered function:

```bash
func new \
  --name HealthCheck \
  --template "HTTP trigger" \
  --authlevel anonymous
```

Brief explanation:

- `--name HealthCheck` becomes both the function name and part of its default route.
- `--template "HTTP trigger"` runs the function when it receives an HTTP request.
- `--authlevel anonymous` allows calls without a function key. This is convenient for the sandbox but should be reviewed for a production endpoint.

Open `HealthCheck.cs` and identify the `[HttpTrigger(...)]` attribute. The trigger is attached to a method argument rather than configured through a web application router. Changing the trigger type could turn the same task into a timer- or queue-driven function with limited changes to its business logic.

### 2. Run and call the function locally

Start the Functions host:

```bash
func start
```

For an isolated .NET project, Core Tools may recommend this equivalent command:

```bash
dotnet run
```

The function list should include an address similar to:

```text
HealthCheck: [GET,POST] http://localhost:7071/api/HealthCheck
```

Call it from another terminal:

```bash
curl -s -w "\nHTTP %{http_code}\n" \
  http://localhost:7071/api/HealthCheck
```

Expected result:

```text
Welcome to Azure Functions!
HTTP 200
```

The `curl` flags hide progress output, preserve the response body and append the HTTP status code.

You may see an unhealthy `AzureWebJobsStorage` message locally when Azurite is not running. The Function can still answer HTTP requests, but the warning demonstrates that a Function App depends on storage for runtime state and coordination.

Stop the host with Ctrl+C, but keep the sandbox project for the Azure deployments.

### 3. Provision the Function App through the portal

Create or reuse the resource group:

```bash
az group create \
  --name rg-clo25-name \
  --location westeurope
```

In the Azure portal, open **Function App → Create** and select **Flex Consumption**. Use:

| Setting | Value |
|---|---|
| Resource group | `rg-clo25-name` |
| Function App name | `func-clo25-name` |
| Region | West Europe |
| Runtime stack | .NET |
| Version | 10 (LTS), isolated worker model |
| Instance size | 2048 MB |
| Zone redundancy | Disabled |

Review the Storage tab to see the storage account dependency created for the app. Before creating the app, confirm that the summary says Linux and Flex Consumption.

Verify the resulting plan from the terminal:

```bash
az appservice plan list \
  --resource-group rg-clo25-name \
  --query "[].{Name:name, Sku:sku.name, Tier:sku.tier, Kind:kind}" \
  --output table
```

The plan should report `FC1` and `FlexConsumption`. The JMESPath expression in `--query` selects only the useful fields and gives them readable column names.

From the `MinFunction` folder, publish the code:

```bash
func azure functionapp publish func-clo25-name
```

Confirm that the output reports `net10.0`, a successful build and a successful deployment. Copy the exact **Invoke URL** printed by the command; portal-created apps may use a secure hostname with a random suffix.

```bash
curl -s -o /dev/null -w "HTTP %{http_code} in %{time_total}s\n" \
  "<paste-the-invoke-url-here>"
```

Expected result: HTTP `200`.

### 4. Provision the same environment with Azure CLI

Create the required storage account:

```bash
az storage account create \
  --name stclo25name \
  --resource-group rg-clo25-name \
  --location westeurope \
  --sku Standard_LRS \
  --query "{Name:name, State:provisioningState, Sku:sku.name}" \
  --output table
```

Brief explanation:

- `Standard_LRS` stores redundant copies within one region.
- `--query` reduces the large Azure response to the resource name, state and SKU.
- The expected provisioning state is `Succeeded`.

Create a second Function App with a distinct name:

```bash
az functionapp create \
  --name func-clo25-cli-name \
  --resource-group rg-clo25-name \
  --storage-account stclo25name \
  --flexconsumption-location westeurope \
  --runtime dotnet-isolated \
  --runtime-version 10.0 \
  --functions-version 4
```

Brief explanation:

- `--flexconsumption-location` selects both the supported region and the Flex Consumption plan type.
- `--runtime dotnet-isolated` and `--runtime-version 10.0` select .NET 10 isolated.
- `--functions-version 4` selects the current Functions host generation used by the exercise.
- Azure also creates a blob container for the deployment package, even though that resource is not explicit in this command.

Verify the plan again with `az appservice plan list`. It should use SKU `FC1` and tier `FlexConsumption`.

Publish from the sandbox project:

```bash
func azure functionapp publish func-clo25-cli-name
```

Call the Function:

```bash
curl -s -o /dev/null -w "HTTP %{http_code} in %{time_total}s\n" \
  https://func-clo25-cli-name.azurewebsites.net/api/healthcheck
```

Run the command twice and compare `time_total`. A slower first call can be evidence of a cold start; a warm app may respond quickly both times.

### 5. Describe the Function infrastructure with Bicep

Return to the course repository and create `infra/functionapp.bicep`:

```bicep
@description('Region. Defaults to the resource group location.')
param location string = resourceGroup().location

@description('Globally unique storage account name.')
param storageAccountName string

@description('Flex Consumption plan name.')
param planName string

@description('Globally unique Function App name.')
param functionAppName string

@description('Owner tag.')
param owner string

var tags = {
  owner: owner
  course: 'clo25'
  environment: 'dev'
  'managed-by': 'bicep'
}

resource storage 'Microsoft.Storage/storageAccounts@2026-04-01' = {
  name: storageAccountName
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
  }
}

resource deploymentContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2026-04-01' = {
  name: '${storage.name}/default/app-package'
}

resource plan 'Microsoft.Web/serverfarms@2025-03-01' = {
  name: planName
  location: location
  tags: tags
  sku: {
    name: 'FC1'
    tier: 'FlexConsumption'
  }
  kind: 'functionapp'
  properties: {
    reserved: true
  }
}

resource functionApp 'Microsoft.Web/sites@2025-03-01' = {
  name: functionAppName
  location: location
  tags: tags
  kind: 'functionapp,linux'
  properties: {
    serverFarmId: plan.id
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${storage.properties.primaryEndpoints.blob}app-package'
          authentication: {
            type: 'StorageAccountConnectionString'
            storageAccountConnectionStringName: 'DEPLOYMENT_STORAGE_CONNECTION_STRING'
          }
        }
      }
      scaleAndConcurrency: {
        maximumInstanceCount: 40
        instanceMemoryMB: 2048
      }
      runtime: {
        name: 'dotnet-isolated'
        version: '10.0'
      }
    }
    siteConfig: {
      appSettings: [
        {
          name: 'AzureWebJobsStorage'
          value: 'DefaultEndpointsProtocol=https;AccountName=${storage.name};AccountKey=${storage.listKeys().keys[0].value};EndpointSuffix=core.windows.net'
        }
        {
          name: 'DEPLOYMENT_STORAGE_CONNECTION_STRING'
          value: 'DefaultEndpointsProtocol=https;AccountName=${storage.name};AccountKey=${storage.listKeys().keys[0].value};EndpointSuffix=core.windows.net'
        }
      ]
    }
  }
  dependsOn: [
    deploymentContainer
  ]
}

output functionAppHost string = functionApp.properties.defaultHostName
```

Brief code explanation:

- The parameters keep environment-specific names outside the resource definitions.
- `tags` applies consistent ownership and environment metadata.
- `storage` provides runtime and deployment storage with TLS 1.2 and no public blob access.
- `deploymentContainer` explicitly creates the package container that Azure CLI created implicitly.
- `plan` selects Linux Flex Consumption through `FC1` and `FlexConsumption`.
- `serverFarmId: plan.id` connects the Function App to that plan.
- `maximumInstanceCount` and `instanceMemoryMB` define the scale ceiling and memory per instance.
- `storage.listKeys()` obtains the key at deployment time; no key is hard-coded in the template.
- `dependsOn` ensures that the package container exists before the Function App is provisioned.
- The output returns the generated hostname for later deployment or verification steps.

Create `infra/functionapp.bicepparam`:

```bicep
using './functionapp.bicep'

param storageAccountName = 'stclo25bicepname'
param planName = 'asp-clo25-func-name'
param functionAppName = 'func-clo25-bicep-name'
param owner = 'name'
```

`using` links the parameter file to its template. The relative path is resolved from the parameter file, not from the terminal’s current directory.

Deploy from the course repository root:

```bash
az deployment group create \
  --resource-group rg-clo25-name \
  --parameters infra/functionapp.bicepparam \
  --query "{State:properties.provisioningState, Host:properties.outputs.functionAppHost.value}" \
  --output table
```

`--template-file` is unnecessary because the parameter file identifies the template. The expected state is `Succeeded`.

Return to `MinFunction`, publish and call the Function:

```bash
func azure functionapp publish func-clo25-bicep-name

curl -s -w "\nHTTP %{http_code}\n" \
  https://func-clo25-bicep-name.azurewebsites.net/api/healthcheck
```

The expected result is the same body and HTTP `200`, now from an environment that can be recreated from versioned infrastructure code.

### 6. Verify runtime support for the VG decision

First inspect all Function runtimes:

```bash
az functionapp list-runtimes --output json
```

Narrow the result to the Linux isolated .NET runtime:

```bash
az functionapp list-runtimes \
  --query "linux[?runtime=='dotnet-isolated']" \
  --output json
```

The result should contain .NET 10 and Functions version 4. The older `dotnet` runtime is the in-process model, while modern .NET versions use `dotnet-isolated`.

Verify the runtime against the actual Flex Consumption plan in West Europe:

```bash
az functionapp list-flexconsumption-runtimes \
  --location westeurope \
  --runtime dotnet-isolated \
  --output table
```

Record from your own output:

- whether .NET 10 is available
- the end-of-life date reported for the chosen runtime
- which version Azure marks as the default

This distinction matters for VG reasoning: platform-wide runtime support does not prove that a specific plan and region support it. Also, a default version is not automatically the best recommendation.

If the region is uncertain, list supported locations:

```bash
az functionapp list-flexconsumption-locations --output table
```

### 7. Calculate the VG cost evidence

Open the Azure Pricing Calculator and configure Azure Functions with:

- Flex Consumption
- West Europe
- 2048 MB memory per instance
- a realistic number of monthly executions for your application
- a realistic average duration per execution

The exercise uses this monthly free allowance as its calculation basis:

| Item | Free allowance |
|---|---:|
| Executions | 250,000 |
| Execution time | 100,000 GB-seconds |

At 2048 MB, or 2 GB, the execution-time allowance corresponds to:

```text
100,000 GB-seconds / 2 GB = 50,000 seconds
```

If each execution lasts 0.5 seconds:

```text
50,000 seconds / 0.5 seconds = 100,000 executions
```

Do not copy this example as your final VG evidence. Enter the expected workload for your own project and record:

1. estimated executions per month
2. estimated average duration
3. configured memory
4. calculated monthly execution time in GB-seconds
5. estimated monthly price
6. comparison with the existing App Service solution

Because prices and allowances can change, include the date and calculator configuration in `TUTORIAL.md`.

### 8. Evaluate the non-financial VG costs

Estimate these costs even if the calculator shows little or no Azure charge:

| Cost | Question to answer |
|---|---|
| Infrastructure | How much extra Bicep, storage and pipeline work is required? |
| Documentation | What must be added so another developer can operate the Function? |
| Cold start | Can the first caller tolerate additional latency? |
| Complexity | Can the team explain, test and maintain triggers, bindings and a second deployment lifecycle? |

Use evidence from the exercise: the four-resource Bicep template shows the infrastructure overhead, and the first-versus-second request timings provide cold-start evidence when observed.

### 9. Write the VG decision in `TUTORIAL.md`

Add a section titled **Alternatives considered – Azure Functions**. Use this structure:

> I considered moving **[specific task]** to an Azure Function with a **[queue/timer/HTTP] trigger**, because **[expected technical benefit]**. I chose to **[build/not build]** it because **[runtime evidence, calculated workload and operational trade-off]**. At **[specific workload, latency requirement or operational threshold]**, the opposite choice would be preferable because **[reason]**.

A strong VG paragraph must include:

- one specific task from your own application
- the trigger that matches that task
- verified .NET 10, plan and region support
- at least one number you produced yourself
- both financial and operational costs
- your chosen option and a clear reason
- a measurable boundary where the decision would change

Avoid conclusions such as “I did not have time.” VG requires a choice based on need. For example, a threshold expressed as monthly executions, maximum acceptable cold-start latency or required isolation makes the decision testable and defensible.

## Verification

The exercise is complete when:

- the local Function returns HTTP `200`
- the Azure-hosted Function returns the same response
- the Flex Consumption plans report SKU `FC1`
- the Bicep deployment reports `Succeeded`
- `infra/functionapp.bicep` explicitly declares storage, package container, plan and Function App
- Azure reports .NET 10 isolated support for Flex Consumption in the selected region
- you have recorded your own workload and price assumptions
- `TUTORIAL.md` contains the VG decision paragraph with a measurable decision boundary

The last two items are the assessed VG result. A working Function alone does not demonstrate the required architectural reasoning.

## Cleanup

Delete the resource group when you have finished comparing the three Azure environments:

```bash
az group delete \
  --name rg-clo25-name \
  --yes \
  --no-wait
```

Verify the deletion later:

```bash
az group exists --name rg-clo25-name
```

Expected result:

```text
false
```
