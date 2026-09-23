# Labb 5: kör Beacon i Azure Container Apps

## Mål

Du ska paketera Beacon som en container, lagra imagen i ett eget Azure Container Registry (ACR) och köra den i Azure Container Apps. Efter labben kan en push bygga en ny image, och du kan verifiera vilken revision som faktiskt körs.

## Förkunskaper

Du behöver Beacon-repot med
 `infra/main.bicep`, `scripts/deploy-infra.sh`, `scripts/health-check.sh` och App Service-workflowet från tidigare labbar. Du behöver också .NET 10, Azure CLI med `az containerapp`, GitHub CLI och tillgång till en Azure-prenumeration. Docker behövs för lokal körning och för Plan B:s pipeline; den första imagen kan annars byggas med `az acr build`.

Kontrollera anslutningarna från repots rot:

```bash
az group list --output table
az containerapp --help
gh auth status
gh secret list
docker --version
```

Om `AZURE_CREDENTIALS` finns som GitHub-secret kan du använda **Plan A**, där pipeline-körningen även rullar ut imagen. Annars använder du **Plan B**: pipeline-körningen bygger och pushar imagen, och du rullar ut den från terminalen.

Exemplen använder `rg-clo25-namn`, `acrclo25namn`, `cae-clo25-namn` och `ca-clo25-namn`. Ersätt `namn` med ditt eget förnamn överallt. ACR-namnet får bara innehålla små bokstäver och siffror och måste vara globalt unikt. Kontrollera det:

```bash
az acr check-name --name acrclo25namn --output table
```

På Git Bash i Windows kör du också `export MSYS_NO_PATHCONV=1`, så att Azure-sökvägar inte skrivs om till lokala filsökvägar.

## Steg

### 1. Återskapa den befintliga infrastrukturen

Om resursgruppen togs bort efter Labb 4 skapar det befintliga skriptet App Service-planen och webbappen igen:

```bash
./scripts/deploy-infra.sh rg-clo25-namn
az webapp show --resource-group rg-clo25-namn --name app-clo25-namn --query state --output tsv
```

Förväntad status är `Running`. En ny webbapp kan ändå ge `404` på `/health` tills koden har deployats; Bicep-mallen skapar infrastrukturen men innehåller inte appens publicerade kod.

### 2. Skriv Dockerfile bredvid webbprojektet

Skapa `src/Beacon.Api/Dockerfile`:

```dockerfile
# Build with the full .NET SDK.
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
ARG PROJECT=src/Beacon.Api/Beacon.Api.csproj
WORKDIR /src
COPY . .
RUN dotnet restore ./$PROJECT
RUN dotnet publish ./$PROJECT \
    --configuration Release \
    --output /app/publish

# Run only the published output with the smaller ASP.NET runtime.
FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS final
WORKDIR /app
COPY --from=build /app/publish .
ENTRYPOINT ["dotnet", "Beacon.Api.dll"]
```

Kort om kodraderna:

- De två `FROM`-raderna gör bygget **multi-stage**: SDK:n används för byggning, men följer inte med i den färdiga imagen.
- `ARG PROJECT` samlar sökvägen till rätt `.csproj` på ett ställe. `COPY . .` använder repots rot som byggkontext.
- `dotnet publish` skapar den körbara appen; `COPY --from=build` tar endast det publicerade resultatet till runtime-imagen.
- `ENTRYPOINT` måste använda projektets verkliga DLL-namn.

### 3. Skapa `.dockerignore` i repots rot

Byggkontexten är repots rot, så `.dockerignore` ska ligga där, inte bredvid Dockerfile:

```dockerignore
**/bin/
**/obj/
**/publish/
artifacts/
.git/
.gitignore
.github/
infra/
azure-credentials.json
publish-profile.xml
*.publishsettings
**/.vs/
**/.vscode/
**/.idea/
**/*.user
**/*.http
.DS_Store
```

`**/bin/` och `**/obj/` utesluter genererade filer på alla katalognivåer. `.git/`, editorfiler och Bicep-filer behövs inte när appen byggs eller körs. Mönstren för credentials skyddar också mot att lokala hemlighetsfiler skickas till Docker-bygget. Det gör byggkontexten mindre och minskar risken att ovidkommande filer följer med.

### 4. Bygg och kör containern lokalt

Stå i repots rot och bygg imagen:

```bash
docker build --file src/Beacon.Api/Dockerfile --tag beacon:local .
docker run --rm --publish 8080:8080 beacon:local
```

Punkten på slutet av `docker build` betyder att repots rot är byggkontext. `--file` pekar på Dockerfilen. I `docker run` mappar `--publish 8080:8080` porten på datorn till porten i containern; `--rm` tar bort containern när den stoppas.

Läs loggen. Den ska ange `Now listening on: http://[::]:8080`. Om din app lyssnar på en annan port ska du använda den som `targetPort` i Bicep senare.

Verifiera från en andra terminal:

```bash
./scripts/health-check.sh http://localhost:8080/health
```

Förväntat är `OK: app responded 200`. Stoppa containern med Ctrl+C. Om Docker saknas kan du fortfarande bygga imagen i Azure i steg 8, men då kan du inte göra denna lokala verifiering.

### 5. Spara containerfilerna

```bash
git add src/Beacon.Api/Dockerfile .dockerignore
git commit -m "Add Dockerfile for the container track"
```

Vänta med `git push` tills container pipelinen är klar. Den befintliga App Service-pipelinen kan annars starta utan att använda de nya filerna.

### 6. Registrera Azure-resurstyperna

En prenumeration måste känna till resurstypen innan den används första gången:

```bash
for namespace in Microsoft.ContainerRegistry Microsoft.App Microsoft.KeyVault; do
  az provider register --namespace "$namespace" --wait
done
```

Kontrollera att samtliga svarar `Registered`:

```bash
for namespace in Microsoft.ContainerRegistry Microsoft.App Microsoft.KeyVault; do
  az provider show --namespace "$namespace" --query registrationState --output tsv
done
```

### 7. Skapa registret med den första Bicep-versionen

Skapa först `infra/container.bicep` med enbart ACR. Container App-delen läggs till när imagen faktiskt finns.

```bicep
@description('Region. Defaults to the resource group location.')
param location string = resourceGroup().location

@description('Globally unique registry name: lowercase letters and digits.')
@minLength(5)
@maxLength(50)
param registryName string

@allowed([
  'Basic'
  'Standard'
  'Premium'
])
param registrySku string = 'Basic'

resource acr 'Microsoft.ContainerRegistry/registries@2025-11-01' = {
  name: registryName
  location: location
  sku: {
    name: registrySku
  }
  properties: {
    adminUserEnabled: true
  }
}

output loginServer string = acr.properties.loginServer
```

Skapa `infra/container.bicepparam`:

```bicep
using './container.bicep'

param registryName = 'acrclo25namn'
```

`adminUserEnabled: true` slår på användarnamn och lösenord för hela registret så att Container App kan hämta imagen. Det är en medveten labbförenkling; managed identity med rollen `AcrPull` är ett säkrare nästa steg. Skriv aldrig registerlösenordet i Bicep eller Git.

Validera.

```bash
az bicep build --file infra/container.bicep && rm -f infra/container.json
```

Förhandsgranska.

```bash
az deployment group what-if \
  --resource-group rg-clo25-namn \
  --template-file infra/container.bicep \
  --parameters infra/container.bicepparam
```

Deploya.

```bash
az deployment group create \
  --name registry-first \
  --resource-group rg-clo25-namn \
  --template-file infra/container.bicep \
  --parameters infra/container.bicepparam \
  --query properties.outputs \
  --output json
```

What-if ska visa ett `+` för registret. `*` för den befintliga App Service-planen och webbappen betyder att de lämnas orörda. Deploymentens `loginServer` bör ha formen `acrclo25namn.azurecr.io`.

### 8. Bygg och pusha den första imagen till ACR

```bash
az acr build \
  --registry acrclo25namn \
  --image beacon:v1 \
  --file src/Beacon.Api/Dockerfile \
  .
```

`az acr build` skickar byggkontexten till Azure och bygger imagen där. Lokal Docker-inloggning behövs inte. Verifiera att taggen finns:

```bash
az acr repository show-tags \
  --name acrclo25namn \
  --repository beacon \
  --output table
```

Förväntat resultat innehåller `v1`. Ordningen är viktig: **registry → image → Container App**. Appen kan inte starta med en image som ännu inte finns.

### 9. Utöka Bicep-mallen med Container Apps

Ersätt innehållet i `infra/container.bicep` med den fullständiga mallen:

```bicep
@description('Region. Defaults to the resource group location.')
param location string = resourceGroup().location

@description('Globally unique registry name.')
@minLength(5)
@maxLength(50)
param registryName string

@allowed([
  'Basic'
  'Standard'
  'Premium'
])
param registrySku string = 'Basic'

param environmentName string
param containerAppName string
param containerImage string
param targetPort int = 8080

@minValue(0)
@maxValue(5)
param minReplicas int = 1

@minValue(1)
@maxValue(10)
param maxReplicas int = 5

param concurrentRequests int = 20

@allowed([
  '0.25'
  '0.5'
  '0.75'
  '1.0'
])
param containerCpu string = '0.5'

@allowed([
  '0.5Gi'
  '1.0Gi'
  '1.5Gi'
  '2.0Gi'
])
param containerMemory string = '1.0Gi'

var registryPasswordSecretName = 'acr-password'
var appFqdn = app.properties.configuration.ingress.fqdn

resource acr 'Microsoft.ContainerRegistry/registries@2025-11-01' = {
  name: registryName
  location: location
  sku: {
    name: registrySku
  }
  properties: {
    adminUserEnabled: true
  }
}

resource environment 'Microsoft.App/managedEnvironments@2026-01-01' = {
  name: environmentName
  location: location
  properties: {}
}

resource app 'Microsoft.App/containerApps@2026-01-01' = {
  name: containerAppName
  location: location
  properties: {
    managedEnvironmentId: environment.id
    configuration: {
      ingress: {
        external: true
        targetPort: targetPort
        allowInsecure: false
        transport: 'auto'
      }
      registries: [
        {
          server: acr.properties.loginServer
          username: acr.listCredentials().username
          passwordSecretRef: registryPasswordSecretName
        }
      ]
      secrets: [
        {
          name: registryPasswordSecretName
          value: acr.listCredentials().passwords[0].value
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'app'
          image: containerImage
          resources: {
            cpu: json(containerCpu)
            memory: containerMemory
          }
        }
      ]
      scale: {
        minReplicas: minReplicas
        maxReplicas: maxReplicas
        rules: [
          {
            name: 'http-scaling'
            http: {
              metadata: {
                concurrentRequests: '${concurrentRequests}'
              }
            }
          }
        ]
      }
    }
  }
}

output loginServer string = acr.properties.loginServer
output appUrl string = 'https://${appFqdn}'
output healthUrl string = 'https://${appFqdn}/health'
```

Uppdatera `infra/container.bicepparam`:

```bicep
using './container.bicep'

param registryName = 'acrclo25namn'
param environmentName = 'cae-clo25-namn'
param containerAppName = 'ca-clo25-namn'
param containerImage = 'acrclo25namn.azurecr.io/beacon:v1'
param minReplicas = 1
param maxReplicas = 5
```

Kort om de viktigaste raderna:

- `targetPort: targetPort` måste matcha porten du såg i containerloggen, normalt `8080`.
- `acr.listCredentials()` hämtar registeruppgifter vid deployment. `passwordSecretRef` pekar på en Container Apps-secret; lösenordet läggs inte i källkoden.
- `cpu: json(containerCpu)` omvandlar strängen `'0.5'` till ett numeriskt värde som Bicep kan skicka vidare. CPU och minne måste vara ett giltigt par, till exempel `0.5` och `1.0Gi`.
- `minReplicas`, `maxReplicas` och `concurrentRequests` anger intervallet och HTTP-regeln för skalning. `minReplicas = 1` undviker skalning till noll och därmed kallstart efter inaktivitet.
- `appFqdn` läser appens verkliga DNS-adress från Azure; adressen ska inte gissas eller hårdkodas.

### 10. Förhandsgranska och deploya Container App

```bash
az bicep build --file infra/container.bicep && rm -f infra/container.json
az deployment group what-if \
  --resource-group rg-clo25-namn \
  --template-file infra/container.bicep \
  --parameters infra/container.bicepparam
```

What-if ska visa `+` på miljön och Container App, men inte på en andra registry-resurs. Registret kan visas som `~` på grund av Azure-genererade standardfält. Stanna om ett oväntat resursnamn skapas eller en resurs visas som borttagen.

Deploya:

```bash
az deployment group create \
  --name container-first \
  --resource-group rg-clo25-namn \
  --template-file infra/container.bicep \
  --parameters infra/container.bicepparam \
  --query properties.outputs \
  --output json
```

Förväntat är `loginServer`, `appUrl` och `healthUrl` i resultatet. Miljön kan ta flera minuter att skapa.

### 11. Verifiera app, image och skalning

Hämta URL:en från Azure och kör samma hälsokontroll som tidigare:

```bash
TARGET_URL="https://$(az containerapp show \
  --resource-group rg-clo25-namn \
  --name ca-clo25-namn \
  --query properties.configuration.ingress.fqdn \
  --output tsv)/health"
./scripts/health-check.sh "$TARGET_URL"
```

Kontrollera sedan revisionen, image-referensen och skalningsregeln:

```bash
az containerapp revision list --resource-group rg-clo25-namn --name ca-clo25-namn \
  --query "[].{Rev:name, Active:properties.active}" --output table
az containerapp show --resource-group rg-clo25-namn --name ca-clo25-namn \
  --query properties.template.containers[0].image --output tsv
az containerapp show --resource-group rg-clo25-namn --name ca-clo25-namn \
  --query properties.template.scale --output json
```

Du ska se en aktiv revision, imagen `beacon:v1` i ditt registry och de replika- och HTTP-värden som anges i parameterfilen. En grön Bicep-deployment är inte bevis på att appen svarar; därför behövs `/health`-kontrollen.

### 12. Skapa ett återanvändbart container-deployskript

Kopiera det befintliga infrastrukturskriptet:

```bash
cp scripts/deploy-infra.sh scripts/deploy-container.sh
```

```bash
scripts/deploy-container.sh
```

```bash
#!/usr/bin/env bash
# Deploys the infrastructure for the container track
# (Container Apps environment + container app). Run from the repo root.
# Requires the registry to exist and the image to be pushed.
# Usage: ./scripts/deploy-container.sh [--what-if] <resource-group> [parameter-file]
# With --what-if the deployment is only previewed. No resources change; the
# resource group itself is still created if missing, because what-if needs it.

set -euo pipefail

# Read the optional flag first, then drop it, so the arguments below keep their
# positions whether or not it was given.
WHAT_IF=false
if [ "${1:-}" = "--what-if" ]; then
  WHAT_IF=true
  shift
fi

RESOURCE_GROUP="${1:?Provide the resource group as the first argument}"
PARAM_FILE="${2:-infra/container.bicepparam}"
LOCATION="${LOCATION:-westeurope}"
TEMPLATE="infra/container.bicep"

echo "Template:       $TEMPLATE"
echo "Parameters:     $PARAM_FILE"
echo "Resource group: $RESOURCE_GROUP"

# Came along with the copy from deploy-infra.sh, and it belongs here too: the
# group is gone after every teardown.
if [ "$(az group exists --name "$RESOURCE_GROUP")" = "false" ]; then
  echo "Group:          missing, creating it in $LOCATION"
  az group create --name "$RESOURCE_GROUP" --location "$LOCATION" --output none
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

DEPLOYMENT_NAME="container-$(date +%Y%m%d-%H%M%S)"
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

Ändra den nya filen så att standardparametrarna pekar på `infra/container.bicepparam`, mallen på `infra/container.bicep` och deploymentsnamnet börjar med `container-`. Behåll argumentkontrollen, skapandet av resursgruppen och `--what-if`-grenen. Kontrollera de exakta skillnaderna med:

```bash
diff -u scripts/deploy-infra.sh scripts/deploy-container.sh
```

Bash command  ```bash -n scripts/deploy-container.sh```

```bash
chmod +x scripts/deploy-container.sh
./scripts/deploy-container.sh --what-if rg-clo25-namn
./scripts/deploy-container.sh rg-clo25-namn
```

`--what-if` visar förväntade resursändringar. Utan flaggan gör skriptet deploymenten. Skriptet ska användas när infrastrukturen ändras, inte för varje ny image: parameterfilen pekar fortfarande på `:v1` och skulle annars kunna rulla tillbaka en senare version.

### 13A. Plan A: bygg och deploya i GitHub Actions

Om GitHub har `AZURE_CREDENTIALS` och identiteten har behörighet på resursgruppen skapar du `.github/workflows/deploy-container.yml`:

```yaml
name: Build and deploy the container to Container Apps

on:
  push:
    branches: [main]
    paths-ignore: ['**.md']
  workflow_dispatch:

env:
  AZURE_RESOURCE_GROUP: rg-clo25-namn
  ACR_NAME: acrclo25namn
  CONTAINER_APP_NAME: ca-clo25-namn
  IMAGE_NAME: beacon

jobs:
  build-and-push:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - uses: actions/setup-dotnet@v6
        with:
          dotnet-version: '10.0.x'
      - name: Run tests
        run: dotnet test --configuration Release
      - uses: azure/login@v3
        with:
          creds: ${{ secrets.AZURE_CREDENTIALS }}
      - name: Build and push in ACR
        run: |
          az acr build \
            --registry "${{ env.ACR_NAME }}" \
            --image "${{ env.IMAGE_NAME }}:${{ github.sha }}" \
            --image "${{ env.IMAGE_NAME }}:latest" \
            --file src/Beacon.Api/Dockerfile .

  deploy:
    needs: build-and-push
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - uses: azure/login@v3
        with:
          creds: ${{ secrets.AZURE_CREDENTIALS }}
      - name: Roll out a new revision
        run: |
          IMAGE="${{ env.ACR_NAME }}.azurecr.io/${{ env.IMAGE_NAME }}"
          az containerapp update \
            --name "${{ env.CONTAINER_APP_NAME }}" \
            --resource-group "${{ env.AZURE_RESOURCE_GROUP }}" \
            --image "$IMAGE:${{ github.sha }}"
      - name: Check health
        run: |
          FQDN=$(az containerapp show \
            --name "${{ env.CONTAINER_APP_NAME }}" \
            --resource-group "${{ env.AZURE_RESOURCE_GROUP }}" \
            --query properties.configuration.ingress.fqdn --output tsv)
          ./scripts/health-check.sh "https://$FQDN/health"
```

`dotnet test` stoppar bygget om tester misslyckas. `needs: build-and-push` hindrar deployment innan imagen finns. `${{ github.sha }}` ger varje image en unik tagg och därmed en ny revisionsreferens; `latest` finns bara som bekväm pekare och används inte för utrullningen. Varje jobb måste logga in separat eftersom det körs på en egen runner.

Om resursgruppen har återskapats behöver service principalen återfå sin Contributor-roll på den nya gruppen innan workflowet kan lyckas. Kontrollera först att `CLIENT_ID` pekar på rätt identitet och återställ rollen med ett konto som får tilldela roller:

```bash
CLIENT_ID=$(az ad app list \
  --display-name sp-clo25-namn \
  --query "[?displayName=='sp-clo25-namn'].appId" \
  --output tsv)

az role assignment create \
  --assignee "$CLIENT_ID" \
  --role Contributor \
  --scope "/subscriptions/$(az account show --query id --output tsv)/resourceGroups/rg-clo25-namn"
```

Om `CLIENT_ID` är tomt eller rollen redan finns ska du undersöka det innan du kör tilldelningskommandot.

### 13B. Plan B: bygg och pusha i pipeline, rulla ut manuellt

Om GitHub saknar Azure-identitet behöver ACR:s adminlösenord läggas i en GitHub-secret:

```bash
az acr credential show --name acrclo25namn --query "passwords[0].value" --output tsv \
  | gh secret set ACR_PASSWORD
```

Skapa `.github/workflows/deploy-container.yml`:

```yaml
name: Build and push the container image to ACR

on:
  push:
    branches: [main]
    paths-ignore: ['**.md']
  workflow_dispatch:

env:
  ACR_LOGIN_SERVER: acrclo25namn.azurecr.io
  ACR_USERNAME: acrclo25namn
  IMAGE_NAME: beacon

jobs:
  build-and-push:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - uses: actions/setup-dotnet@v6
        with:
          dotnet-version: '10.0.x'
      - name: Run tests
        run: dotnet test --configuration Release
      - uses: docker/login-action@v4
        with:
          registry: ${{ env.ACR_LOGIN_SERVER }}
          username: ${{ env.ACR_USERNAME }}
          password: ${{ secrets.ACR_PASSWORD }}
      - name: Build and push
        run: |
          IMAGE="${{ env.ACR_LOGIN_SERVER }}/${{ env.IMAGE_NAME }}"
          docker build -f src/Beacon.Api/Dockerfile \
            -t "$IMAGE:${{ github.sha }}" -t "$IMAGE:latest" .
          docker push "$IMAGE:${{ github.sha }}"
          docker push "$IMAGE:latest"
```

Här bygger runnerns Docker imagen eftersom `az acr build` hade krävt en Azure-identitet. Endast lösenordet är hemligt; ACR-adress och användarnamn är konfiguration. När workflowet är grönt rullar du ut **samma commit-hash** från din terminal:

```bash
az containerapp update \
  --name ca-clo25-namn \
  --resource-group rg-clo25-namn \
  --image acrclo25namn.azurecr.io/beacon:$(git rev-parse HEAD)
```

Dokumentera att utrullningen sker manuellt eftersom pipeline-körningen saknar Azure-rättigheter. Ett framtida alternativ är federerad OIDC-inloggning och managed identity med `AcrPull`.

### 14. Verifiera att en push verkligen uppdaterar appen

Commit och pusha workflowet och skriptet:

```bash
git add .github/workflows/deploy-container.yml scripts/deploy-container.sh infra/ .gitignore
git commit -m "Add pipeline for the container track"
git push
```

Följ körningen:

```bash
gh run list --workflow deploy-container.yml --limit 5
```

Gör sedan en liten synlig kodändring, committa och pusha den. Plan B kör utrullningskommandot ovan efter att imagen pushats. Verifiera både `/health`, det synliga nya svaret och revisionerna:

```bash
./scripts/health-check.sh "$TARGET_URL"
az containerapp revision list \
  --resource-group rg-clo25-namn \
  --name ca-clo25-namn \
  --all \
  --query "[].{Rev:name, Active:properties.active}" \
  --output table
```

`--all` visar även äldre, inaktiva revisioner. En lyckad health check bevisar bara att **någon** revision svarar; den bevisar inte ensam att den nya revisionen fått trafik. Kontrollera därför revisionslistan och det synliga svaret.

### 15. Skapa ett skript för full återuppbyggnad

Skapa `scripts/provision-all.sh` för ordningen App Service → registry → image → Container App:

```bash
#!/usr/bin/env bash
set -euo pipefail

RESOURCE_GROUP="${1:?Provide the resource group as the first argument}"
ACR_NAME="${2:?Provide your ACR name as the second argument}"
IMAGE_TAG="${3:-v1}"

echo "== 1/4 App Service infrastructure =="
./scripts/deploy-infra.sh "$RESOURCE_GROUP"

echo "== 2/4 Registry =="
az acr create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$ACR_NAME" \
  --sku Basic \
  --admin-enabled true \
  --output none

echo "== 3/4 Image =="
az acr build \
  --registry "$ACR_NAME" \
  --image "beacon:$IMAGE_TAG" \
  --file src/Beacon.Api/Dockerfile .

echo "== 4/4 Container Apps infrastructure =="
./scripts/deploy-container.sh "$RESOURCE_GROUP"

echo "Both tracks are up."
```

De fyra rubrikerna visar beroendeordningen. `RESOURCE_GROUP` och `ACR_NAME` är obligatoriska argument; `IMAGE_TAG` får standardvärdet `v1`. Skriptet skapar inte ny logik för Bicep utan återanvänder de två deployskripten.

Kontrollera syntax och körbarhet innan du sparar det:

```bash
chmod +x scripts/provision-all.sh
bash -n scripts/provision-all.sh
git add scripts/provision-all.sh
git commit -m "Add a script that builds the whole environment back up"
git push
```

`bash -n` kör inget mot Azure; tyst utdata betyder att Bash-syntaxen är giltig.

Skriptet utgår från att `container.bicepparam` pekar på samma image-tagg som det bygger (`v1` som standard). Ändrar du tredje argumentet måste du även uppdatera `containerImage` i parameterfilen. Efter att en Plan B-registry har återskapats behöver du också uppdatera GitHub-secreten `ACR_PASSWORD`, eftersom det gamla registry-lösenordet inte längre gäller.

## Verifiering

Labbens slutresultat är verifierat när:

- Dockerfile och `.dockerignore` finns på rätt platser och containern svarar lokalt på `/health`.
- ACR innehåller minst en `beacon`-tagg.
- Container App svarar `200` på `/health`.
- Azure visar rätt image, aktiv revision och avsedda scale-regler.
- `deploy-container.sh` fungerar med och utan `--what-if`.
- Container-workflowet är grönt och en ny kodändring ger en ny revision.
- App Service-spåret finns kvar och fungerar separat.
- `provision-all.sh` klarar `bash -n`.

Om appen inte startar, läs plattformens loggar först:

```bash
az containerapp logs show \
  --resource-group rg-clo25-namn \
  --name ca-clo25-namn \
  --type system \
  --tail 50
```

`ImagePullFailure` pekar oftast på fel image-tagg eller registry-uppgifter. `502` kan betyda att `targetPort` inte matchar appens verkliga port.

## Städning

Container Apps-miljön och ACR kan medföra kostnader. Spara först eventuella observationsdata du behöver; deploymenthistorik och images försvinner när resursgruppen tas bort. Kontrollera gruppnamnet noggrant och kör:

```bash
az group delete --name rg-clo25-namn --yes --no-wait
az group show --name rg-clo25-namn \
  --query properties.provisioningState --output tsv 2>/dev/null || echo "Borta"
```

`Deleting` betyder att borttagningen pågår. `Borta` betyder att gruppen inte längre finns. Nästa gång återskapar du båda spåren med:

```bash
./scripts/provision-all.sh rg-clo25-namn acrclo25namn
```
