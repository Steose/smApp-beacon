# Labb 4: hantera Beacon-infrastrukturen med Bicep

## Mål

I den här tutorialen beskriver du Beacons App Service-plan och webbapp som Infrastructure as Code med Bicep. Du validerar och driftsätter mallen, verifierar att den är idempotent och kopplar deploymenten till ditt arbetsflöde antingen automatiskt eller via ett dokumenterat lokalt skript.

## Förkunskaper

Du behöver:

- Beacon-repot med workflow och `scripts/health-check.sh` från Labb 3
- Azure CLI 2.89 eller senare
- Bicep CLI
- GitHub CLI för Plan A och för automatisk nyckelrotation i Plan B
- Bash, Zsh, Git Bash eller WSL
- en aktiv Azure-prenumeration
- namnen på resursgruppen, webbappen och App Service-planen

Kontrollera verktyg och inloggningar:

```bash
az version
az bicep version
az account show --output table
gh auth status
```

Installera eller uppdatera vid behov:

```bash
az bicep install
az upgrade
az login
```

Om du använder Git Bash på Windows kör du en gång per terminalfönster:

```bash
export MSYS_NO_PATHCONV=1
```

Det förhindrar att Git Bash skriver om Azure-sökvägar som börjar med `/subscriptions/`.

Exemplen använder:

- `rg-clo25-namn`
- `asp-clo25-namn`
- `app-clo25-namn`
- `sp-clo25-namn`

> **Varning:** `namn` är en platshållare. Ersätt det med ditt eget förnamn överallt och använd exakt samma stavning.

## Steg

### 1. Återskapa och verifiera appen

Följ din tidigare dokumentation för att återskapa resursgrupp, plan och webbapp om de har tagits bort. Publicera och driftsätt därefter Beacon.

Kontrollera appen med det återanvändbara skriptet:

```bash
TARGET_URL="https://$(az webapp show \
  --resource-group rg-clo25-namn \
  --name app-clo25-namn \
  --query defaultHostName \
  --output tsv)/health"

./scripts/health-check.sh "$TARGET_URL"
```

Kort kodförklaring:

- `$(...)` kör Azure-kommandot och placerar dess resultat i URL:en.
- `--query defaultHostName` väljer endast appens värdnamn.
- `--output tsv` returnerar värdet utan JSON eller citattecken.
- `"$TARGET_URL"` skickar hela adressen som ett säkert argument till skriptet.

Fortsätt när skriptet får HTTP-status `200`.

Om appen har återskapats och pipeline-körningen fortfarande använder en publish profile behöver SCM basic authentication aktiveras och GitHub-hemligheten uppdateras:

```bash
az resource update \
  --resource-group rg-clo25-namn \
  --namespace Microsoft.Web \
  --resource-type basicPublishingCredentialsPolicies \
  --name scm \
  --parent sites/app-clo25-namn \
  --set properties.allow=true

az webapp deployment list-publishing-profiles \
  --name app-clo25-namn \
  --resource-group rg-clo25-namn \
  --xml > publish-profile.xml

gh secret set AZURE_WEBAPP_PUBLISH_PROFILE < publish-profile.xml
rm publish-profile.xml
```

### 2. Välj Plan A eller Plan B

Valet avgör vem som kör Bicep-deploymenten:

- **Plan A:** GitHub Actions använder en service principal och driftsätter infrastrukturen automatiskt.
- **Plan B:** Du kör samma Bicep-mall manuellt med Azure-inloggningen i terminalen.

Plan B är ett fullständigt IaC-flöde; endast exekveringsplatsen skiljer sig.

För Plan A kontrollerar du först GitHub-hemligheterna:

```bash
gh secret list
```

Listan ska innehålla `AZURE_CREDENTIALS`. Kontrollera sedan om identiteten finns:

```bash
CLIENT_ID=$(az ad app list \
  --display-name sp-clo25-namn \
  --query "[?displayName=='sp-clo25-namn'].appId" \
  --output tsv)

echo "$CLIENT_ID"
```

En tom rad betyder att identiteten saknas. Om du inte får skapa en service principal använder du Plan B. Om den finns kontrollerar du rollen:

```bash
az role assignment list \
  --assignee "$CLIENT_ID" \
  --resource-group rg-clo25-namn \
  --output table
```

Plan A kräver rollen `Contributor` med scope på resursgruppen. Ett smalt resursgruppsscope följer least privilege-principen: pipeline-körningen får hantera labbresurserna men inte hela prenumerationen.

### 3. Läs den befintliga appens konfiguration

Kontrollera operativsystem, runtime och plan innan mallen skrivs:

```bash
az webapp show \
  --resource-group rg-clo25-namn \
  --name app-clo25-namn \
  --query "{kind:kind, runtime:siteConfig.linuxFxVersion, plan:serverFarmId}" \
  --output json
```

För en Linux-app förväntas:

```json
{
  "kind": "app,linux",
  "runtime": "DOTNETCORE|10.0",
  "plan": ".../serverfarms/asp-clo25-namn"
}
```

Om `plan` är `null` kan en äldre CLI använda fältet `appServicePlanId`. Uppdatera Azure CLI eller byt fältnamn i frågan. Kontrollera även planens riktiga namn:

```bash
az appservice plan list \
  --resource-group rg-clo25-namn \
  --output table
```

Azure CLI använder runtimeformen `DOTNETCORE:10.0`, medan Bicep-egenskapen använder `DOTNETCORE|10.0`.

### 4. Skapa Bicep-mallen

Skapa infrastrukturmappen:

```bash
mkdir -p infra
```

Skapa `infra/main.bicep`:

```bicep
// Infrastructure for the web app track: App Service plan + web app.
// Deployed into an existing resource group with az deployment group create.

@description('Region. Defaults to the location of the resource group.')
param location string = resourceGroup().location

@description('Name of the web app. Part of the URL, must be globally unique.')
param appName string

@description('Name of the App Service plan.')
param planName string

@description('Plan size. B1 = Basic, P0v3 = Premium v3.')
@allowed([
  'B1'
  'P0v3'
])
param skuName string = 'B1'

@description('Number of instances to run. B1 allows a maximum of 3.')
@minValue(1)
@maxValue(3)
param instanceCount int = 2

var runtimeStack = 'DOTNETCORE|10.0'
var healthCheckPath = '/health'

resource plan 'Microsoft.Web/serverfarms@2025-03-01' = {
  name: planName
  location: location
  kind: 'linux'
  sku: {
    name: skuName
    capacity: instanceCount
  }
  properties: {
    reserved: true
  }
}

resource app 'Microsoft.Web/sites@2025-03-01' = {
  name: appName
  location: location
  kind: 'app,linux'
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    siteConfig: {
      linuxFxVersion: runtimeStack
      healthCheckPath: healthCheckPath
      minTlsVersion: '1.3'
      alwaysOn: true
    }
  }
}

var hostName = app.properties.defaultHostName

output appUrl string = 'https://${hostName}'
output healthUrl string = 'https://${hostName}${healthCheckPath}'
```

Mallen deklarerar skalning genom `capacity: instanceCount`, tvingar HTTPS, kräver minst TLS 1.3, aktiverar `alwaysOn` och konfigurerar `/health`.

Kort kodförklaring:

- `param` gör värden konfigurerbara utan att mallen behöver ändras.
- `@allowed`, `@minValue` och `@maxValue` stoppar ogiltiga parametervärden före deployment.
- `resourceGroup().location` använder samma region som resursgruppen.
- `resource plan` beskriver App Service-planen och `capacity` styr antalet instanser.
- `reserved: true` anger att planen använder Linux.
- `resource app` beskriver webbappen och `serverFarmId: plan.id` kopplar den till planen.
- `httpsOnly`, `minTlsVersion` och `healthCheckPath` anger säkerhets- och robusthetskrav.
- `output` returnerar appens adresser efter deploymenten.

För en Windows-app behöver `kind`, `reserved` och runtime-egenskapen anpassas: använd `kind: 'app'`, `reserved: false` och `netFrameworkVersion: 'v10.0'` i stället för `linuxFxVersion`.

Deklarera inte `appSettings` i den här mallen. En deklarerad lista ersätter befintliga inställningar, inklusive sådana appen redan kan behöva.

### 5. Skapa parameterfilen

Skapa `infra/main.bicepparam`:

```bicep
using './main.bicep'

param appName = 'app-clo25-namn'
param planName = 'asp-clo25-namn'
param instanceCount = 3
```

Ersätt båda `namn`-värdena. Namnen ska exakt matcha resurserna från steg 3. Fel namn skapar nya resurser i stället för att uppdatera de befintliga.

Parameterfilen får inte innehålla lösenord, nycklar eller anslutningssträngar eftersom den committas till Git.

`using './main.bicep'` kopplar parameterfilen till mallen. Varje `param` tilldelar ett konkret värde till motsvarande parameter i `main.bicep`.

### 6. Ignorera genererad ARM-JSON

Kontrollera att `.gitignore` innehåller:

```gitignore
infra/*.json
```

Bicep kompileras till ARM-JSON, men den genererade filen ska inte versionshanteras.

### 7. Validera mallen och parameterfilen

Bygg mallen:

```bash
az bicep build --file infra/main.bicep
```

Tystnad betyder att bygget lyckades. Läs alla `BCP`-varningar: de kan indikera felstavade egenskaper eller fel datatyp även när kompileringen fortsätter.

Validera parameterfilen separat:

```bash
az bicep build-params \
  --file infra/main.bicepparam \
  --stdout > /dev/null
```

`build` kontrollerar och kompilerar själva mallen. `build-params` kontrollerar att parameterfilen passar mallen. `--stdout > /dev/null` validerar resultatet utan att spara ännu en genererad fil.

Ta bort den genererade JSON-filen:

```bash
rm infra/main.json
```

### 8. Förhandsgranska med what-if

```bash
az deployment group what-if \
  --resource-group rg-clo25-namn \
  --template-file infra/main.bicep \
  --parameters infra/main.bicepparam
```

Läs symbolerna på **resursnivån**:

| Symbol | Betydelse | Åtgärd |
|---|---|---|
| `~` | Befintlig resurs ändras | Förväntat första gången |
| `=` | Resursen stämmer redan | Förväntat efter deployment |
| `+` | Ny resurs ska skapas | Kontrollera app- och plannamn |
| `-` | Resurs ska raderas | Stoppa och granska innan deployment |
| `*` | Befintlig resurs lämnas orörd | Kontrollera om fel resursnamn används |

Fortsätt endast när appen och planen visas som `~` eller `=`. Ett `+` på appen eller planen betyder normalt att parameterfilens namn inte matchar de befintliga resurserna.

What-if kan överrapportera egenskapsändringar för App Service. Använd det för att upptäcka stora resursförändringar och kontrollera sedan verkliga egenskaper direkt från Azure.

### 9. Driftsätt mallen

```bash
az deployment group create \
  --name webapp-infra-first \
  --resource-group rg-clo25-namn \
  --template-file infra/main.bicep \
  --parameters infra/main.bicepparam \
  --query properties.outputs \
  --output json
```

Förväntad form på resultatet:

```json
{
  "appUrl": {
    "type": "String",
    "value": "https://app-clo25-namn.azurewebsites.net"
  },
  "healthUrl": {
    "type": "String",
    "value": "https://app-clo25-namn.azurewebsites.net/health"
  }
}
```

Deploymentens `--name` identifierar posten i Azures deploymenthistorik, inte en resurs. Visa historiken med:

```bash
az deployment group list \
  --resource-group rg-clo25-namn \
  --query "[].{Name:name, State:properties.provisioningState}" \
  --output table
```

Kort kommandoförklaring:

- `az deployment group create` tillämpar mallen på en befintlig resursgrupp.
- `--template-file` väljer Bicep-mallen.
- `--parameters` läser värdena från parameterfilen.
- `--query properties.outputs` visar endast mallens output-värden.

### 10. Verifiera appen och skalningen

Deploymentstatus visar bara att Azure tillämpade mallen. Kontrollera appen separat:

```bash
TARGET_URL="https://$(az webapp show \
  --resource-group rg-clo25-namn \
  --name app-clo25-namn \
  --query defaultHostName \
  --output tsv)/health"

./scripts/health-check.sh "$TARGET_URL"
```

Status `000` eller `503` kan visas medan appen startar om. Kör skriptet igen om den första omgången inte räcker. Kontrollera loggen efter två misslyckade omgångar:

```bash
az webapp log tail \
  --resource-group rg-clo25-namn \
  --name app-clo25-namn
```

Verifiera plan och instansantal:

```bash
az appservice plan list \
  --resource-group rg-clo25-namn \
  --query "[].{Name:name, Sku:sku.name, Capacity:sku.capacity}" \
  --output table
```

Det ska finnas en plan med rätt namn och det instansantal som anges i parameterfilen.

### 11. Bevisa idempotens

Kör what-if igen och kontrollera verkliga egenskaper:

```bash
az deployment group what-if \
  --resource-group rg-clo25-namn \
  --template-file infra/main.bicep \
  --parameters infra/main.bicepparam

az webapp show \
  --resource-group rg-clo25-namn \
  --name app-clo25-namn \
  --query "{https:httpsOnly, alwaysOn:siteConfig.alwaysOn}" \
  --output json
```

Kör samma deployment igen:

```bash
az deployment group create \
  --name webapp-infra-again \
  --resource-group rg-clo25-namn \
  --template-file infra/main.bicep \
  --parameters infra/main.bicepparam \
  --query properties.provisioningState \
  --output tsv
```

Förväntat svar är `Succeeded`. Egenskaperna och instansantalet ska vara oförändrade. Detta visar idempotens: samma deklaration kan köras upprepade gånger utan att skapa dubbletter eller ändra slutresultatet.

### 12. Committa infrastrukturen

```bash
git add infra/ .gitignore
git commit -m "Add Bicep template for App Service"
git push
```

Kontrollera före commiten att `infra/main.json` inte läggs till.

### 13. Skapa deploymentskriptet

Skapa `scripts/deploy-infra.sh`:

```bash
#!/usr/bin/env bash
# Usage: ./scripts/deploy-infra.sh [--what-if] <resource-group> [parameter-file]

set -euo pipefail

WHAT_IF=false
if [ "${1:-}" = "--what-if" ]; then
  WHAT_IF=true
  shift
fi

RESOURCE_GROUP="${1:?Provide the resource group as the first argument}"
PARAM_FILE="${2:-infra/main.bicepparam}"
LOCATION="${LOCATION:-westeurope}"
TEMPLATE="infra/main.bicep"

echo "Template:       $TEMPLATE"
echo "Parameters:     $PARAM_FILE"
echo "Resource group: $RESOURCE_GROUP"

if [ "$(az group exists --name "$RESOURCE_GROUP")" = "false" ]; then
  echo "Group:          missing, creating it in $LOCATION"
  az group create \
    --name "$RESOURCE_GROUP" \
    --location "$LOCATION" \
    --output none
else
  echo "Group:          already exists"
fi

if [ "$WHAT_IF" = true ]; then
  echo "Mode:           preview (no resources change)"
  az deployment group what-if \
    --resource-group "$RESOURCE_GROUP" \
    --template-file "$TEMPLATE" \
    --parameters "$PARAM_FILE"
  exit 0
fi

DEPLOYMENT_NAME="webapp-$(date +%Y%m%d-%H%M%S)"
echo "Mode:           deploy ($DEPLOYMENT_NAME)"

APP_URL=$(az deployment group create \
  --name "$DEPLOYMENT_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --template-file "$TEMPLATE" \
  --parameters "$PARAM_FILE" \
  --query properties.outputs.appUrl.value \
  --output tsv)

echo "Done. App URL: $APP_URL"
```

Skriptet skapar resursgruppen om den saknas, stöder ett säkert `--what-if`-läge och använder ett unikt deploymentsnamn per körning.

Kort kodförklaring:

- `set -euo pipefail` stoppar skriptet vid fel, odefinierade variabler och fel i pipelines.
- `${1:-}` betyder första argumentet, eller en tom sträng om det saknas.
- `shift` tar bort `--what-if` så att resursgruppen därefter alltid ligger i `$1`.
- `${1:?meddelande}` kräver ett argument och visar meddelandet om det saknas.
- `${2:-infra/main.bicepparam}` använder parameterfilen som standardvärde.
- `${LOCATION:-westeurope}` tillåter att regionen skrivs över med en miljövariabel.
- Kontrollen med `az group exists` gör skriptet återanvändbart även efter att resursgruppen har tagits bort.
- `date +%Y%m%d-%H%M%S` ger varje deployment ett unikt och läsbart namn.
- `APP_URL=$(...)` sparar mallens output i en variabel i stället för att skriva hela Azure-svaret.

### 14. Testa skriptet i båda lägena

```bash
chmod +x scripts/deploy-infra.sh
bash -n scripts/deploy-infra.sh
./scripts/deploy-infra.sh --what-if rg-clo25-namn
```

Fortsätt endast om resursraderna visas som `~` eller `=`. Driftsätt sedan:

```bash
./scripts/deploy-infra.sh rg-clo25-namn
```

Förväntad avslutning:

```text
Done. App URL: https://app-clo25-namn.azurewebsites.net
```

Verifiera appen genom att kedja skripten:

```bash
./scripts/deploy-infra.sh rg-clo25-namn
./scripts/health-check.sh "$TARGET_URL"
```

### 15A. Plan A: lägg infrastrukturen i pipeline-körningen

Lägg till resursgruppen under `env` i `.github/workflows/deploy.yml`:

```yaml
env:
  AZURE_WEBAPP_NAME: app-clo25-namn
  AZURE_WEBAPP_HOSTNAME: app-clo25-namn.azurewebsites.net
  AZURE_RESOURCE_GROUP: rg-clo25-namn
  DOTNET_VERSION: '10.0.x'
```

Lägg till `infra` under den befintliga `jobs:`-nyckeln:

```yaml
  infra:
    runs-on: ubuntu-latest
    steps:
      - name: Check out the code
        uses: actions/checkout@v7

      - name: Sign in to Azure
        uses: azure/login@v3
        with:
          creds: ${{ secrets.AZURE_CREDENTIALS }}

      - name: Deploy the infrastructure
        run: |
          chmod +x ./scripts/deploy-infra.sh
          ./scripts/deploy-infra.sh "${{ env.AZURE_RESOURCE_GROUP }}"
```

Ändra sedan deploy-jobbets beroende:

```yaml
  deploy:
    needs: [build, infra]
```

`build` och `infra` körs parallellt. `deploy` startar först när båda har lyckats.

Kort YAML-förklaring:

- `runs-on: ubuntu-latest` väljer GitHub-runnern.
- `actions/checkout` hämtar repots filer så att skript och Bicep-mall finns tillgängliga.
- `azure/login` loggar in med identiteten i `AZURE_CREDENTIALS`.
- `${{ env.AZURE_RESOURCE_GROUP }}` läser resursgruppen från workflowets `env`.
- `needs: [build, infra]` skapar beroendet som hindrar koddeployment innan både bygge och infrastruktur är klara.

```bash
git add .github/workflows/deploy.yml scripts/ infra/ .gitignore
git commit -m "Run Bicep deployment from the pipeline"
git push
```

Följ körningen:

```bash
sleep 10
RUN_ID=$(gh run list --limit 1 --json databaseId --jq '.[0].databaseId')
gh run watch "$RUN_ID"
```

### 15B. Plan B: dokumentera manuell deployment

Om du saknar rätt att skapa eller använda en service principal lämnar du Bicep-deploymenten utanför pipeline-körningen. Committa samma mall, parameterfil och skript:

```bash
git add scripts/ infra/ .gitignore
git commit -m "Add the infra deploy script, run from the terminal"
git push
```

Dokumentera att:

- `scripts/deploy-infra.sh` kör Bicep-deploymenten manuellt
- pipeline-körningen saknar en identitet med rätt att skapa resurser
- en publish profile kan ladda upp kod men inte skapa Azure-resurser
- nästa steg är federerade credentials med OIDC, utan lagrat lösenord

### 16A. Plan A: ersätt publish profile med identiteten

Lägg till Azure-inloggning efter artifact-nedladdningen men före App Service-deploymenten:

```yaml
      - name: Download artifact
        uses: actions/download-artifact@v8
        with:
          name: 'app'
          path: 'artifacts/publish'

      - name: Sign in to Azure
        uses: azure/login@v3
        with:
          creds: ${{ secrets.AZURE_CREDENTIALS }}

      - name: Deploy to App Service
        uses: azure/webapps-deploy@v3
        with:
          app-name: ${{ env.AZURE_WEBAPP_NAME }}
          package: 'artifacts/publish'
```

Ta bort raden `publish-profile:`. Pusha och kontrollera att hela kedjan är grön:

```bash
git add .github/workflows/deploy.yml
git commit -m "Authenticate the deploy job with the service principal"
git push
```

När den nya pipeline-körningen har lyckats kan den oanvända hemligheten tas bort:

```bash
gh secret delete AZURE_WEBAPP_PUBLISH_PROFILE
```

Service principalen överlever när resursgruppen tas bort, men en rolltilldelning med resursgruppsscope gör det inte. Tilldela därför rollen igen efter att gruppen återskapats, eller automatisera kontrollen i skriptet. Att använda prenumerationsscope hade överlevt rivningen men gett identiteten onödigt bred behörighet.

### 16A.1 Plan A: återställ Contributor-rollen automatiskt

Lägg identitetens namn bland variablerna i `scripts/deploy-infra.sh`:

```bash
SP_NAME="${SP_NAME:-sp-clo25-namn}"
```

Lägg sedan följande sist i skriptet. Blocket återställer rollen om resursgruppen har återskapats och tilldelningen därför saknas:

```bash
if [ -z "${SP_OBJECT_ID:-}" ]; then
  SP_OBJECT_ID=$(az ad sp list \
    --display-name "$SP_NAME" \
    --query "[?displayName=='$SP_NAME'].id" \
    --output tsv 2>/dev/null || true)
fi

if [ -n "${SP_OBJECT_ID:-}" ]; then
  SCOPE="/subscriptions/$(az account show --query id --output tsv)"
  SCOPE="$SCOPE/resourceGroups/$RESOURCE_GROUP"

  EXISTING=$(az role assignment list \
    --assignee-object-id "$SP_OBJECT_ID" \
    --scope "$SCOPE" \
    --fill-principal-name false \
    --query "[0].id" \
    --output tsv)

  if [ -z "$EXISTING" ]; then
    echo "Role:           granting Contributor to the pipeline identity"
    az role assignment create \
      --assignee-object-id "$SP_OBJECT_ID" \
      --assignee-principal-type ServicePrincipal \
      --role Contributor \
      --scope "$SCOPE" \
      --output none
  else
    echo "Role:           pipeline identity already has Contributor"
  fi
fi
```

Kort kodförklaring:

- Skriptet slår upp `objectId` från identitetens namn i stället för att lägga ett tenant-id i Git.
- `--assignee-object-id` undviker ett extra Microsoft Graph-uppslag när rollen kontrolleras.
- `--fill-principal-name false` minskar behovet av katalogbehörigheter.
- `SCOPE` begränsar rollen till labbens resursgrupp enligt least privilege.
- `EXISTING` gör blocket idempotent: rollen skapas bara om den saknas.
- `2>/dev/null || true` gör uppslagningen frivillig när pipeline-identiteten saknar rätt att läsa katalogen.
- `${SP_OBJECT_ID:-}` fungerar även med `set -u` när variabeln inte är satt.

Kör skriptet lokalt efter ändringen. På Git Bash behöver `MSYS_NO_PATHCONV=1` vara satt eftersom scopet börjar med `/subscriptions/`.

### 16B. Plan B: automatisera publish-profile-rotationen

En publish profile är bunden till en viss appinstans och blir ogiltig när appen återskapas. Lägg följande sist i `scripts/deploy-infra.sh` och ersätt `namn`:

```bash
APP_NAME="${APP_NAME:-app-clo25-namn}"

az resource update \
  --resource-group "$RESOURCE_GROUP" \
  --namespace Microsoft.Web \
  --resource-type basicPublishingCredentialsPolicies \
  --name scm \
  --parent "sites/$APP_NAME" \
  --set properties.allow=true \
  --output none

if command -v gh > /dev/null 2>&1; then
  echo "Secret:         rotating AZURE_WEBAPP_PUBLISH_PROFILE"
  az webapp deployment list-publishing-profiles \
    --name "$APP_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --xml | gh secret set AZURE_WEBAPP_PUBLISH_PROFILE
else
  echo "Secret:         gh is not installed, so the secret was NOT rotated."
  echo "                Set it by hand, or your next push will fail to deploy."
fi
```

Blocket aktiverar SCM-inloggning, hämtar den nya profilen och uppdaterar GitHub-hemligheten. Om `RequestDisallowedByPolicy` visas förbjuder prenumerationen basic authentication; använd då en identitetsbaserad lösning i samråd med administratören.

Kort kodförklaring:

- `${APP_NAME:-app-clo25-namn}` använder miljövariabeln `APP_NAME` om den finns, annars standardnamnet.
- `command -v gh` kontrollerar om GitHub CLI är installerat.
- `| gh secret set ...` skickar profilen direkt till GitHub utan en lokal mellanfil.
- `else` ger en tydlig varning när hemligheten måste uppdateras manuellt.

## Felsökning

| Fel | Orsak | Åtgärd |
|---|---|---|
| `plan` blir `null` | Azure CLI använder äldre fältnamn | Uppdatera CLI eller fråga efter `appServicePlanId` |
| `BCP089` | Egenskap är felstavad | Använd stavningen som Bicep föreslår |
| `BCP036` | Fel datatyp | Ta exempelvis bort citattecken runt booleska värden |
| `BCP258` | Parameter saknas | Lägg till exempelvis `param planName` i parameterfilen |
| What-if visar `+` på planen eller appen | Namnet matchar inte befintlig resurs | Rätta `main.bicepparam`; deploya inte |
| `AuthorizationFailed` | Identiteten saknar rätt scope eller roll | Kontrollera Contributor-tilldelningen |
| Instanskvot eller kapacitetsfel | Regionen tillåter inte önskat antal | Sänk `instanceCount`, begär kvot eller byt region |
| Appen svarar `503` efter deployment | Appen startar om | Vänta och kör health check-skriptet igen |
| `Login failed` i pipeline-körningen | `AZURE_CREDENTIALS` saknas eller är ofullständig | Kontrollera secret, identitet och roll |
| `Permission denied` för skriptet | Körbarhetsflaggan saknas | Kör `chmod +x` och committa filens mode |
| Deploy startar före infra | Fel `needs` | Använd `needs: [build, infra]` |

Om instansantalet överskrider kvoten ändrar du parameterfilen till två eller en instans och dokumenterar begränsningen. Poängen är att skalningen styrs deklarativt i filen.

## Verifiering

Tutorialen är klar när:

- `infra/main.bicep` och `infra/main.bicepparam` är committade
- `az bicep build` och `build-params` lyckas
- what-if inte visar oväntade skapanden eller borttagningar
- deploymenten lyckas och `/health` svarar med `200`
- endast en App Service-plan finns och den har rätt instansantal
- samma deployment kan köras igen utan ändrat slutresultat
- `scripts/deploy-infra.sh` fungerar i både `--what-if`-läge och deploymentläge
- Plan A har ett grönt `infra`-jobb, eller Plan B är tydligt motiverad
- du kan peka på `capacity: instanceCount` som raden som styr skalningen

## Städning

Deployment historik ligger i resursgruppen och försvinner med den. Kontrollera den innan du river om du behöver den för dokumentation.

Läs gruppnamnet noggrant och ta bort hela resursgruppen:

```bash
az group delete \
  --name rg-clo25-namn \
  --yes \
  --no-wait
```

Kontrollera senare att borttagningen är klar:

```bash
az group exists --name rg-clo25-namn
```

Förväntat svar:

```text
false
```

Nästa gång kan infrastrukturen återskapas med ett kommando:

```bash
./scripts/deploy-infra.sh rg-clo25-namn
```

För Plan A behöver Contributor-rollen återställas om dess scope låg på den borttagna resursgruppen. Identiteten finns kvar i Entra ID, men resursgruppens rolltilldelning tas bort tillsammans med gruppen.
