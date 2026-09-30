# Tutorial

## Vad appen är

Beacon är en enkel webbapp som visar applikationens status och systeminformation via olika API-endpoints.

## Så kör du den lokalt

### Steg 1. Kontrollera inloggning

```bash
az account show --output table
```

```bash
EnvironmentName    HomeTenantId                          IsDefault      Name                  State    TenantDefaultDomain                    TenantDisplayName    TenantId
-----------------  ------------------------------------  -----------    --------------------  -------  -----------------------------------    -------------------  ------------------------------------
AzureCloud         398f8eeb-4883-4648-baf8-72f7667c1a3e  True           Azure subscription 1  Enabled  osedummestevengmail.onmicrosoft.com    Default Directory    398f8eeb-4883-4648-baf8-72f7667c1a3e
```

### Steg 2. Skapa resouce group

```bash
az group create \
  --name rg-clo25-steven \
  --location swedencentral
```

### Steg 3. Skapa maskinerna och appen

Två saker i tur och ordning:

Först- planen. Det är maskinerna, appen ska köra på, och det är den du skalar.

```bash
az appservice plan create \
  --name asp-clo25-steven \
  --resource-group rg-clo25-steven \
  --location swedencentral \
  --sku B1 \
  --is-linux \
  --async-scaling-enabled true
```

```text
    --async-scaling-enabled flag lets Azure complete the allocation when capacity becomes available
```

Andra - appen, som kopplas till planen med --plan:

```bash
az webapp create \
  --name app-clo25-steven \
  --resource-group rg-clo25-steven \
  --plan asp-clo25-steven \
  --runtime "DOTNETCORE:10.0"
```

### Steg 4. Skicka upp koden

Appen är nu tillgänglig, men är tom. ```az webapp deploy``` vill ha en zip-fil, inte en mapp, så appen bör byggas och paketeras innan den skickas.
Lägger in paketeringen i projektfilen en gång. Öppna Beacon.Api.csproj och lägg till detta precis före ```</Project>```:

```XML
<!-- Packar publiceringen till app.zip, bredvid publiceringsmappen -->
  <Target Name="ZipPublishOutput" AfterTargets="Publish">
    <ZipDirectory SourceDirectory="$(PublishDir)"
                  DestinationFile="$(PublishDir)../app.zip"
                  Overwrite="true" />
  </Target>
```

```bash
dotnet publish src/Beacon.Api --configuration Release --output artifacts/publish
```

```bash
az webapp deploy \
  --resource-group rg-clo25-steven \
  --name app-clo25-steven \
  --src-path artifacts/app.zip \
  --type zip
```

Att kontrollera: ```ls artifacts/```
Du se ```app.zip``` och mappen ```publish/```

Slutar med ```"status": "RuntimeSuccessful"```.

### Steg 5.  Verifiera att appen svarar

```bash
curl -s -o /dev/null -w "%{http_code}\n" \
  https://app-clo25-steven.azurewebsites.net/health
```

```bash
curl -s -o /dev/null -w "%{http_code}\n" \
  https://app-clo25-steven.azurewebsites.net/info
```  

Svar: ```200```

### Skala Ut Och Verifiera 

```bash
for i in $(seq 1 10); do
  curl --silent https://app-clo25-steven.azurewebsites.net/visits
  echo
done
```

```bash
{"visits":1,"machine":"186d7fa1abd1"}
{"visits":1,"machine":"80c1f4bbd7d1"}
{"visits":2,"machine":"80c1f4bbd7d1"}
{"visits":1,"machine":"11534e66dbda"}
{"visits":2,"machine":"186d7fa1abd1"}
{"visits":3,"machine":"186d7fa1abd1"}
{"visits":3,"machine":"80c1f4bbd7d1"}
{"visits":4,"machine":"186d7fa1abd1"}
{"visits":5,"machine":"186d7fa1abd1"}
{"visits":2,"machine":"11534e66dbda"}
```

Putting a counter in the application code does not maintain a consistent count across different instances of the application, as each instance has its own separate counter and it means that the App does not keep any state in memory. This is evident from the varying visit counts returned by different machines, indicating that the state is not shared between them.

### 1. Läs av planen

```bash
az appservice plan list \
  --resource-group rg-clo25-steven \
  --query "[].{Name:name, Tier:sku.name, Instances:sku.capacity}" \
  --output table
```

Två flaggor som gör läsbara

### Svaret

```bash
Name              Tier    Instances
----------------  ------  -----------
asp-clo25-steven  B1      1
```

En instance = En maskin

### 2. Skala ut till tre instanser

```bash
az appservice plan update \
  --name asp-clo25-steven \
  --resource-group rg-clo25-namn \
  --number-of-workers 3
```

### 3. Kontrollera att det stämmer

```bash
az appservice plan list \
  --resource-group rg-clo25-steven \
  --query "[].{Name:name, Tier:sku.name, Instances:sku.capacity}" \
  --output table
```

Svaret

```bash
Name              Tier    Instances
----------------  ------  -----------
asp-clo25-steven  B1      3
```

## Health check

### 1. Slå på health check

Två vägar -  

1. Portalen.
in App Service -> Monitoring i vänstermenyn -> Health check -> slå på Enable, ange sökvägen /health, och klicka Save

2. Terminalen

```bash
az webapp config set \
  --resource-group rg-clo25-steven \
  --name app-clo25-steven \
  --generic-configurations health_check_path="/health"
```

### Att Kontrollera
```bash
az webapp show \
  --resource-group rg-clo25-steven \
  --name app-clo25-steven \
  --query siteConfig.healthCheckPath \
  --output tsv
```

Svar: ```health```

### Riv

```bash
az group delete \
  --name rg-clo25-namn \
  --yes \
  --no-wait
```

### Kontrollera att den är borta

```bash
az group exists --name rg-clo25-namn
```

### Att Driftsätta som Script fil

```bash
scripts/provision.sh
```

# 1. Slå på basic auth igen. Utan den blir profilen i steg 2 värdelös.
az resource update \
  --resource-group rg-clo25-namn \
  --namespace Microsoft.Web \
  --resource-type basicPublishingCredentialsPolicies \
  --name scm \
  --parent sites/app-clo25-namn \
  --set properties.allow=true

# 2. Hämta den nya appens profil till en fil.
az webapp deployment list-publishing-profiles \
  --name app-clo25-namn \
  --resource-group rg-clo25-namn \
  --xml > publish-profile.xml

# 3. Skicka upp filens innehåll som secret hos GitHub.
gh secret set AZURE_WEBAPP_PUBLISH_PROFILE < publish-profile.xml

# 4. Radera den lokala kopian. Glöm inte den här.
rm publish-profile.xml

## GitHub Actions: skapa `AZURE_CREDENTIALS`

Workflowets `infra`-jobb loggar in i Azure med:

```yaml
- name: Sign in to Azure
  uses: azure/login@v3
  with:
    creds: ${{ secrets.AZURE_CREDENTIALS }}
```

Om GitHub Actions visar följande fel saknas hemligheten eller har fel innehåll:

```text
Using auth-type: SERVICE_PRINCIPAL. Not all values are present.
Ensure 'client-id' and 'tenant-id' are supplied.
```

`AZURE_CREDENTIALS` måste innehålla ett komplett JSON-objekt med `clientId`, `clientSecret`, `subscriptionId` och `tenantId` för en Azure service principal.

### 1. Kontrollera Azure- och GitHub-inloggningen

Kör kommandona från repots rotmapp:

```bash
az login
az account show --output table
gh auth status
```

Kontrollera att rätt Azure-prenumeration är aktiv. Byt vid behov:

```bash
az account set --subscription "DIN-PRENUMERATION"
```

### 2. Hämta prenumerationens ID

```bash
BEACON_SUBSCRIPTION_ID="$(az account show --query id --output tsv)"
echo "$BEACON_SUBSCRIPTION_ID"
```

Resultatet ska vara ett UUID. Lägg aldrig citattecken eller exempelvärden i GitHub-hemligheten.

### 3. Skapa service principalen och GitHub-hemligheten

Workflowet kan skapa den borttagna resursgruppen och behöver därför behörighet på prenumerationsnivå. Följande kommando skapar en service principal med rollen `Contributor` och skickar dess JSON direkt till GitHub:

```bash
az ad sp create-for-rbac \
  --name sp-beacon-github-steven \
  --role Contributor \
  --scopes "/subscriptions/$BEACON_SUBSCRIPTION_ID" \
  --json-auth \
  | gh secret set AZURE_CREDENTIALS
```

Credential-värdet skickas genom pipen och behöver därför inte sparas i en lokal fil. Visa eller dela aldrig värdet. Om kommandot ger ett behörighetsfel behöver en Azure-administratör eller lärare skapa identiteten och rolltilldelningen.

### 4. Kontrollera GitHub-hemligheten

```bash
gh secret list
```

Listan ska innehålla:

```text
AZURE_CREDENTIALS
```

GitHub visar inte hemlighetens värde igen. Det är avsiktligt.

### 5. Kontrollera workflowets miljövariabler

Filen `.github/workflows/deploy.yml` ska innehålla den resursgrupp som skickas till `scripts/deploy-infra.sh`:

```yaml
env:
  AZURE_RESOURCE_GROUP: rg-clo25-steven
  AZURE_WEBAPP_NAME: app-clo25-steven
  AZURE_WEBAPP_HOSTNAME: app-clo25-steven.azurewebsites.net
  DOTNET_VERSION: '10.0.x'
```

Inloggningssteget ska använda den samlade hemligheten:

```yaml
- name: Sign in to Azure
  uses: azure/login@v3
  with:
    creds: ${{ secrets.AZURE_CREDENTIALS }}
```

Ange inte samtidigt `client-id`, `tenant-id` eller `subscription-id` när `creds` används, eftersom individuella värden gör att `creds` ignoreras.

### 6. Starta workflowet igen

En ändrad GitHub-secret kräver ingen ny commit:

```bash
gh workflow run deploy.yml
```

Följ den senaste körningen:

```bash
RUN_ID="$(gh run list --workflow deploy.yml --limit 1 \
  --json databaseId --jq '.[0].databaseId')"

gh run watch "$RUN_ID"
```

Visa felloggen om körningen fortfarande misslyckas:

```bash
gh run view "$RUN_ID" --log-failed
```

### Säkerhet

Filer som `azure-credentials.json` innehåller normalt en `clientSecret`. De får aldrig läggas till med `git add` eller committas. Om credentials redan har committats eller delats ska service principalens lösenord återställas omedelbart och GitHub-hemligheten uppdateras.


## Beslut jag tagit

Jag valde att bygga Beacon eftersom en enkel tjänst för att övervaka en applikations status passar bra för att lära sig hur skalbara molnapplikationer fungerar. Idén gör det möjligt att börja med tydliga endpoints för hälso- och systeminformation och sedan bygga vidare med fler funktioner under kursens gång.
