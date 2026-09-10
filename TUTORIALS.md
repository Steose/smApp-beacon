# Tutorial: driftsätt och skala Beacon i Azure

## Mål

I den här guiden driftsätter du Beacon till Azure App Service, aktiverar health check och skalar ut appen från en till tre instanser. När du är klar har du en körande webbapp med endpoints för status och systeminformation.

Beacon innehåller följande endpoints:

- `/` visar appens namn och status.
- `/health` visar om appen är frisk.
- `/info` visar appens namn och vilken maskin som besvarade anropet.

## Förkunskaper

Du behöver:

- grundläggande kunskaper om terminalkommandon
- .NET 10 SDK
- Azure CLI
- en aktiv Azure-prenumeration
- behörighet att skapa en resursgrupp, en App Service-plan och en webbapp
- Beacon-projektet lokalt

Kommandona ska köras från projektets rotmapp.

## Steg

### 1. Kontrollera din Azure-inloggning

Kontrollera att du är inloggad och att rätt prenumeration är aktiv:

```bash
az account show --output table
```

Om du inte är inloggad kör du:

```bash
az login
```

### 2. Skapa resursgruppen

Skapa resursgruppen `rg-clo25-steven` i regionen Sweden Central:

```bash
az group create \
  --name rg-clo25-steven \
  --location swedencentral
```

Resursgruppen samlar alla Azure-resurser som tillhör Beacon.

### 3. Skapa App Service-planen

Planen innehåller beräkningsresurserna som appen körs på. Det är också planen som skalas ut när appen behöver fler instanser.

```bash
az appservice plan create \
  --name asp-clo25-steven \
  --resource-group rg-clo25-steven \
  --location swedencentral \
  --sku B1 \
  --is-linux \
  --async-scaling-enabled true
```

Flaggan `--sku B1` väljer prisnivån Basic B1 för App Service-planen. Den ger en dedikerad instans och stöd för manuell utskalning.

Flaggan `--is-linux` anger att appen ska köras på Linux-baserade servrar i stället för Windows-baserade servrar.

Flaggan `--async-scaling-enabled true` låter Azure slutföra tilldelningen när kapacitet blir tillgänglig.

### 4. Skapa webbappen

Skapa webbappen och koppla den till App Service-planen med `--plan`:

```bash
az webapp create \
  --name app-clo25-steven \
  --resource-group rg-clo25-steven \
  --plan asp-clo25-steven \
  --runtime "DOTNETCORE|10.0"
```

> **Varning:** Namnet på en Azure-webbapp måste vara globalt unikt. Om `app-clo25-steven` redan används behöver du välja ett annat namn och använda det genom hela guiden.

### 5. Bygg och paketera appen

Webbappen finns nu i Azure men innehåller ännu inte Beacon. Projektfilen `src/Beacon.Api/Beacon.Api.csproj` har ett `ZipPublishOutput`-mål som automatiskt skapar en zip-fil efter publicering.

Publicera appen i Release-läge:

```bash
dotnet publish src/Beacon.Api \
  --configuration Release \
  --output artifacts/publish
```

Kontrollera resultatet:

```bash
ls artifacts
```

Du ska se mappen `publish` och filen `app.zip`.

### 6. Driftsätt appen

Skicka zip-filen till Azure App Service:

```bash
az webapp deploy \
  --resource-group rg-clo25-steven \
  --name app-clo25-steven \
  --src-path artifacts/app.zip \
  --type zip
```

En lyckad driftsättning avslutas med statusen `RuntimeSuccessful`.

### 7. Kontrollera den nuvarande skalningen

Visa App Service-planens nivå och antal instanser:

```bash
az appservice plan list \
  --resource-group rg-clo25-steven \
  --query "[].{Name:name, Tier:sku.name, Instances:sku.capacity}" \
  --output table
```

Före utskalningen ska planen ha en instans:

```text
Name              Tier    Instances
----------------  ------  ---------
asp-clo25-steven  B1      1
```

### 8. Skala ut till tre instanser

Öka antalet arbetare i App Service-planen till tre:

```bash
az appservice plan update \
  --name asp-clo25-steven \
  --resource-group rg-clo25-steven \
  --number-of-workers 3
```

Kontrollera skalningen igen:

```bash
az appservice plan list \
  --resource-group rg-clo25-steven \
  --query "[].{Name:name, Tier:sku.name, Instances:sku.capacity}" \
  --output table
```

Förväntat resultat:

```text
Name              Tier    Instances
----------------  ------  ---------
asp-clo25-steven  B1      3
```

### 9. Aktivera health check

Konfigurera App Service att använda Beacons `/health`-endpoint:

```bash
az webapp config set \
  --resource-group rg-clo25-steven \
  --name app-clo25-steven \
  --generic-configurations '{"healthCheckPath":"/health"}'
```

Du kan också göra detta i Azure-portalen:

1. Öppna webbappen i **App Service**.
2. Välj **Monitoring** och sedan **Health check**.
3. Aktivera health check.
4. Ange sökvägen `/health`.
5. Spara ändringen.

Kontrollera den konfigurerade sökvägen:

```bash
az webapp show \
  --resource-group rg-clo25-steven \
  --name app-clo25-steven \
  --query siteConfig.healthCheckPath \
  --output tsv
```

Förväntat svar:

```text
/health
```

### 10. Alternativ: använd provisioneringsskriptet

Projektet innehåller `scripts/provision.sh`, som skapar resursgruppen, App Service-planen och webbappen samt driftsätter `artifacts/app.zip`.

Bygg paketet först:

```bash
dotnet publish src/Beacon.Api \
  --configuration Release \
  --output artifacts/publish
```

Kör sedan skriptet:

```bash
sh scripts/provision.sh
```

Använd detta som ett alternativ till de manuella stegen 2–6, inte efter att samma resurser redan har skapats.

## Verifiering

Kontrollera att appens endpoints `/health` och `/info` svarar med HTTP-status `200`:

```bash
curl -s -o /dev/null -w "%{http_code}\n" \
  https://app-clo25-steven.azurewebsites.net/health
```

```bash
curl -s -o /dev/null -w "%{http_code}\n" \
  https://app-clo25-steven.azurewebsites.net/info
```

Förväntat svar från båda kommandona:

```text
200
```

Visa innehållet från health-endpointen:

```bash
curl https://app-clo25-steven.azurewebsites.net/health
```

Förväntat JSON-svar:

```json
{
  "status": "healthy",
  "version": "1.0.0"
}
```

## Städning

Azure-resurserna kan medföra kostnader. Ta bort hela resursgruppen när du inte längre behöver appen:

```bash
az group delete \
  --name rg-clo25-steven \
  --yes \
  --no-wait
```

Kontrollera att resursgruppen är borttagen:

```bash
az group exists --name rg-clo25-steven
```

Förväntat svar när borttagningen är klar:

```text
false
```

## Beslut bakom appen

Beacon valdes eftersom en enkel tjänst för att övervaka en applikations status passar bra för att lära sig hur skalbara molnapplikationer fungerar. Tydliga endpoints för hälso- och systeminformation ger en enkel grund som kan byggas ut med fler funktioner under kursens gång.

---

# Labb 3: automatiserad driftsättning och health check-skript

## Mål

I den här guiden kopplar du Beacon till GitHub Actions. Varje push till `main` ska automatiskt:

1. hämta källkoden
2. installera .NET 10
3. återställa beroenden
4. bygga lösningen
5. köra testerna
6. publicera och paketera appen
7. driftsätta paketet till Azure App Service
8. köra ett eget Bash-skript som kontrollerar att `/health` svarar efter driftsättningen

När du är klar ska en misslyckad build, ett misslyckat test, en misslyckad driftsättning eller en otillgänglig app göra hela workflow-körningen röd.

## Förkunskaper

Innan du börjar behöver du följande:

- Beacon finns i ett GitHub-repo och är pushad till GitHub.
- Du har en aktiv Azure-prenumeration och rätt att skapa resurser. Webbappen kan vara borttagen efter föregående labb; den byggs i så fall upp igen i steg 2.
- Beacon har en `/health`-endpoint som returnerar HTTP-status `200` när appen körs.
- Azure CLI är installerat och du är inloggad.
- GitHub CLI är installerat och du är inloggad, eller så använder du GitHubs webbgränssnitt.
- Du kör kommandona i Bash, exempelvis Terminal på macOS/Linux, Git Bash eller WSL på Windows.

Kontrollera verktygen och Azure-prenumerationen:

```bash
bash --version
gh auth status
az account show --output table
```

Om Azure-inloggningen saknas kör du:

```bash
az login
```

## 1. Kontrollera att du får pusha workflow-filer

Visa repots fjärradress:

```bash
git remote -v
```

Om adressen börjar med `git@` använder du SSH och kan gå vidare till nästa steg. Om den börjar med `https://` kontrollerar du raden `Token scopes` i resultatet från `gh auth status`. Om `workflow` saknas lägger du till behörigheten:

```bash
gh auth refresh -h github.com -s workflow
gh auth setup-git
gh auth status
```

När `gh auth refresh` visar en engångskod kopierar du koden och trycker sedan på Enter för att öppna webbläsaren. Kontrollera efteråt att `workflow` står under `Token scopes`.

## 2. Bygg upp Azure-resurserna igen

Om du tog bort resursgruppen efter labb 2 finns det inte längre någon app att driftsätta till. Skapa därför infrastrukturen på nytt med samma namn som tidigare. Att samma namn används i Azure, GitHub-hemligheten och workflowet är viktigt.

Skapa först resursgruppen i West Europe:

```bash
az group create \
  --name rg-clo25-steven \
  --location westeurope
```

Skapa sedan en Linux-baserad App Service-plan på B1-nivån:

```bash
az appservice plan create \
  --name asp-clo25-steven \
  --resource-group rg-clo25-steven \
  --location westeurope \
  --sku B1 \
  --is-linux
```

Ange inte `--number-of-workers`. Planen ska avsiktligt ha **en instans**. Det håller kostnaden nere och blir viktigt när deploymentstrategin analyseras: en rolling deployment kräver flera instanser.

Skapa webbappen:

```bash
az webapp create \
  --name app-clo25-steven \
  --resource-group rg-clo25-steven \
  --plan asp-clo25-steven \
  --runtime "DOTNETCORE:10.0"
```

Webbappsnamnet måste vara globalt unikt. Om Azure meddelar att namnet redan används behöver du välja ett unikt namn och sedan använda exakt samma namn i alla senare kommandon och i workflowets `AZURE_WEBAPP_NAME` och `HEALTH_URL`.

Publicera Beacon lokalt:

```bash
dotnet publish src/Beacon.Api \
  --configuration Release \
  --output artifacts/publish
```

Kontrollera själva resultatet, inte bara texten från `dotnet publish`:

```bash
ls artifacts/
```

Du ska se både mappen `publish/` och filen `app.zip`. Om `app.zip` saknas kontrollerar du att målet `ZipPublishOutput` i `src/Beacon.Api/Beacon.Api.csproj` ligger mellan `</PropertyGroup>` och `</Project>`. Kör sedan publiceringen igen.

Driftsätt zip-filen manuellt för att återställa appen till samma utgångsläge som efter labb 2:

```bash
az webapp deploy \
  --resource-group rg-clo25-steven \
  --name app-clo25-steven \
  --src-path artifacts/app.zip \
  --type zip
```

Vänta tills driftsättningen är klar och verifiera `/health`:

```bash
curl \
  -s \
  -o /dev/null \
  -w "%{http_code}\n" \
  https://app-clo25-steven.azurewebsites.net/health
```

Förväntat resultat är `200`. Resultatet `000` är inte en HTTP-statuskod; det betyder att `curl` inte fick något HTTP-svar. Kontrollera då appnamnet och vänta någon minut medan App Service startar appen.

De manuella kommandona i detta steg visar varför automatisering behövs: idag automatiseras kodens build, test och deployment. I en senare labb kan även infrastrukturen beskrivas i en versionshanterad fil.

## 3. Kör build och tester lokalt

Verifiera lösningen innan du automatiserar den:

```bash
dotnet restore Beacon.sln
dotnet build Beacon.sln --configuration Release --no-restore
dotnet test Beacon.sln --configuration Release --no-build
```

Alla tester ska bli godkända. Åtgärda lokala fel innan du fortsätter, annars kommer samma fel att stoppa GitHub Actions.

## 4. Läs rätt appnamn och adress från Azure

Gissa inte appens adress. Läs både resursnamnet och det Azure-genererade värdnamnet:

```bash
az webapp list \
  --resource-group rg-clo25-steven \
  --query "[].{Name:name, Address:defaultHostName}" \
  --output table
```

Förväntad form på resultatet:

```text
Name                Address
------------------  ------------------------------------------
app-clo25-steven    app-clo25-steven.azurewebsites.net
```

Skriv ner värdena från din egen utskrift. Nyare appar kan få ett extra suffix i värdnamnet, så använd alltid värdet i kolumnen `Address` för `HEALTH_URL`. Namnen `Name` och `Address` i tabellen kommer från aliasen i `--query`; de är inte fasta Azure-fältnamn.

## 5. Aktivera basic authentication för deploymenttjänsten

En publish profile innehåller användarnamn och lösenord till App Services deploymenttjänst. På nya appar kan denna inloggningsväg vara avstängd. Aktivera SCM-principen **innan** profilen hämtas:

```bash
az resource update \
  --resource-group rg-clo25-steven \
  --namespace Microsoft.Web \
  --resource-type basicPublishingCredentialsPolicies \
  --name scm \
  --parent sites/app-clo25-steven \
  --set properties.allow=true \
  --query "properties" \
  --output json
```

Förväntat resultat:

```json
{
  "allow": true
}
```

SCM betyder Source Control Management. App Service har en separat tjänsteadress, `app-clo25-steven.scm.azurewebsites.net`, som bland annat används för deployment, loggström och åtkomst till appens filsystem. Publish-profilen ger åtkomst till denna deploymenttjänst.

Hoppa inte över aktiveringen. Azure kan annars fortfarande skapa en profil som ser riktig ut men saknar ett användbart lösenord; felet märks då först som ett autentiseringsfel i pipeline-körningen.

### Om Azure Policy nekar basic authentication

Om kommandot ger `RequestDisallowedByPolicy` eller ett liknande policyfel ska du inte försöka kringgå organisationens säkerhetspolicy. Hoppa över steg 6–8 och behåll workflowets build- och testdel, men ta bort eller kommentera bort deploymentsteget. Publicera och driftsätt i stället manuellt med din Azure-inloggning:

```bash
dotnet publish src/Beacon.Api \
  --configuration Release \
  --output artifacts/publish

az webapp deploy \
  --resource-group rg-clo25-steven \
  --name app-clo25-steven \
  --src-path artifacts/app.zip \
  --type zip
```

`az webapp deploy` kan använda Entra-token från `az login` när basic authentication är avstängd. Dokumentera då följande i din inlämning:

- Deploymenten körs manuellt med `az webapp deploy`.
- Prenumerationens policy förbjuder basic authentication, som publish profiles bygger på.
- Nästa steg för full automation är att ge pipeline-körningen en egen identitet med en service principal eller federerad inloggning.

## 6. Hämta och kontrollera publish-profilen

Spara profilen till en tillfällig lokal fil:

```bash
az webapp deployment list-publishing-profiles \
  --name app-clo25-steven \
  --resource-group rg-clo25-steven \
  --xml > publish-profile.xml
```

Kommandot skriver inget till skärmen eftersom utdata omdirigeras. Kontrollera början av filen:

```bash
head -c 70 publish-profile.xml
```

Du ska se början av XML-dokumentet och ditt appnamn, exempelvis:

```xml
<publishData><publishProfile profileName="app-clo25-steven - Web Deploy"
```

Kontrollen bekräftar att filen kommer från rätt app. Filen innehåller inloggningsuppgifter och ska behandlas som ett lösenord. Den får aldrig committas.

## 7. Lägg profilen i en GitHub-hemlighet

Läs in hela filen i en repository secret och kontrollera sedan att namnet finns:

```bash
gh secret set AZURE_WEBAPP_PUBLISH_PROFILE < publish-profile.xml
gh secret list
```

Hemligheten måste heta exakt `AZURE_WEBAPP_PUBLISH_PROFILE`. GitHub visar namnet men låter dig inte läsa ut värdet igen.

Utan GitHub CLI öppnar du repot på GitHub och väljer **Settings → Secrets and variables → Actions → New repository secret**. Ange namnet ovan. Öppna `publish-profile.xml`, markera hela innehållet med Ctrl+A eller Cmd+A och klistra in det som värde. XML-filen består normalt av en lång rad; musmarkering kan lätt ge en ofullständig profil och ett svårtolkat autentiseringsfel.

## 8. Radera och ignorera den lokala profilen

När hemligheten finns på GitHub har den lokala kopian inget syfte. Radera den direkt:

```bash
rm publish-profile.xml
```

Kontrollera att följande regler finns i `.gitignore` så att framtida profiler inte kan läggas till av misstag:

```gitignore
publish-profile.xml
*.publishsettings
```

Verifiera att filen är borta och att inga profiler spåras:

```bash
test ! -f publish-profile.xml
git status --short
```

Som frivillig fördjupning kan hämtning, uppladdning och säker borttagning samlas i `scripts/refresh-secret.sh`. Låt resursgrupp och appnamn vara argument, använd en `trap` så att den tillfälliga filen tas bort även vid fel och låt skriptet returnera en icke-noll exitkod när ett kommando misslyckas.

## 9. Skriv verifieringsskriptet

Skapa filen `scripts/health-check.sh` med följande innehåll:

```bash
#!/usr/bin/env bash
set -euo pipefail

url="${1:?Usage: $0 <health-url>}"
max_attempts="${MAX_ATTEMPTS:-12}"
delay_seconds="${DELAY_SECONDS:-10}"

for ((attempt = 1; attempt <= max_attempts; attempt++)); do
  status_code="$(curl \
    --silent \
    --show-error \
    --location \
    --output /dev/null \
    --write-out '%{http_code}' \
    --max-time 15 \
    "$url" || true)"

  if [[ "$status_code" == "200" ]]; then
    echo "Health check succeeded: $url returned HTTP 200."
    exit 0
  fi

  echo "Attempt $attempt/$max_attempts returned HTTP ${status_code:-000}."

  if ((attempt < max_attempts)); then
    sleep "$delay_seconds"
  fi
done

echo "Health check failed: $url did not return HTTP 200." >&2
exit 1
```

Gör filen körbar:

```bash
chmod +x scripts/health-check.sh
```

Skriptet försöker flera gånger eftersom App Service kan behöva en kort stund för att starta den nya versionen. Exitkod `0` betyder att appen svarar. Exitkod `1` betyder att kontrollen misslyckades och gör därmed workflow-körningen röd.

Testa skriptet mot den driftsatta appen:

```bash
./scripts/health-check.sh \
  https://app-clo25-steven.azurewebsites.net/health
```

Testa även felvägen med en adress som inte finns:

```bash
MAX_ATTEMPTS=1 ./scripts/health-check.sh \
  https://app-clo25-steven.azurewebsites.net/does-not-exist
```

Det andra kommandot ska avslutas med ett fel.

## 10. Skapa GitHub Actions-workflowet

Skapa filen `.github/workflows/deploy.yml`:

```yaml
name: Build, test and deploy Beacon

on:
  push:
    branches:
      - main
  workflow_dispatch:

permissions:
  contents: read

concurrency:
  group: beacon-production
  cancel-in-progress: true

env:
  DOTNET_VERSION: 10.0.x
  AZURE_WEBAPP_NAME: app-clo25-steven
  HEALTH_URL: https://app-clo25-steven.azurewebsites.net/health

jobs:
  build-test-deploy:
    runs-on: ubuntu-latest

    steps:
      - name: Check out source code
        uses: actions/checkout@v4

      - name: Set up .NET
        uses: actions/setup-dotnet@v4
        with:
          dotnet-version: ${{ env.DOTNET_VERSION }}

      - name: Restore dependencies
        run: dotnet restore Beacon.sln

      - name: Build
        run: dotnet build Beacon.sln --configuration Release --no-restore

      - name: Test
        run: dotnet test Beacon.sln --configuration Release --no-build

      - name: Publish
        run: dotnet publish src/Beacon.Api/Beacon.Api.csproj --configuration Release --no-build --output publish

      - name: Deploy to Azure App Service
        uses: azure/webapps-deploy@v3
        with:
          app-name: ${{ env.AZURE_WEBAPP_NAME }}
          publish-profile: ${{ secrets.AZURE_WEBAPP_PUBLISH_PROFILE }}
          package: publish

      - name: Verify deployed app
        run: ./scripts/health-check.sh "$HEALTH_URL"
```

`workflow_dispatch` gör att workflowet även kan startas manuellt från GitHub. `concurrency` förhindrar att två produktionsdriftsättningar körs samtidigt. Hemligheten används endast i deploy-steget.

Projektets `ZipPublishOutput`-mål skapar också `app.zip` när `dotnet publish` körs. Workflowet skickar här själva `publish`-mappen till App Service, så zip-filen behöver inte committas.

## 11. Validera workflow-filen lokalt

Kontrollera först att filerna finns och att skriptets syntax är giltig:

```bash
test -f .github/workflows/deploy.yml
test -x scripts/health-check.sh
bash -n scripts/health-check.sh
```

Visa ändringarna innan du committar:

```bash
git status --short
git diff -- .github/workflows/deploy.yml scripts/health-check.sh
```

## 12. Commit och push

Lägg till filerna och pusha dem till `main`:

```bash
git add .github/workflows/deploy.yml scripts/health-check.sh
git commit -m "Add automated Azure deployment pipeline"
git push origin main
```

Om du arbetar på en annan branch pushar du den först och skapar sedan en pull request. Workflowet ovan driftsätter först när ändringen når `main`.

## 13. Följ pipeline-körningen

Med GitHub CLI:

```bash
gh run list --workflow deploy.yml --limit 5
gh run watch
```

I webbläsaren öppnar du repots flik **Actions** och väljer **Build, test and deploy Beacon**.

En lyckad körning ska visa gröna steg för restore, build, test, publish, deploy och verifiering. Kontrollera därefter appen själv:

```bash
curl --fail --show-error \
  https://app-clo25-steven.azurewebsites.net/health
```

## 14. Bevisa att push utlöser pipeline-körningen

Gör en liten, ofarlig ändring, exempelvis i dokumentationen, och pusha den:

```bash
git add TUTORIALS.md
git commit -m "Document automated deployment"
git push origin main
```

Öppna Actions igen och kontrollera att en ny körning startar automatiskt. Detta visar hela kedjan:

```text
git push → build → test → publish → deploy → health check
```

## Vilken deploymentstrategi används?

Workflowet använder en enkel **in-place deployment** till App Services produktionsplats. Paketet kopieras direkt till den aktiva webbappen och ersätter den tidigare versionen. App Service-planen skapades avsiktligt med en enda instans, så detta kan inte vara en rolling deployment, som förutsätter flera instanser som uppdateras i omgångar. Det är inte heller blue-green deployment eller canary deployment.

App Service kan hålla den gamla processen igång en kort stund medan den nya versionen startas, men pipeline-definitionen skapar ingen separat staging slot och utför ingen slot swap. Därför finns risk för en kort störning eller för att ett fel når produktion innan health check-steget upptäcker det. Health checken verifierar resultatet men utför ingen automatisk rollback.

För en säkrare framtida lösning kan du driftsätta till en staging slot, verifiera slotens `/health` och därefter göra en slot swap till produktion. Det motsvarar en blue-green-liknande strategi, men ingår inte i workflowet ovan.

## Vanliga fel

### Push nekas för workflow-filen

Om GitHub meddelar att en OAuth-app inte får skapa eller uppdatera en workflow-fil saknas normalt `workflow`-behörigheten för HTTPS-inloggningen. Kör:

```bash
gh auth refresh -h github.com -s workflow
gh auth setup-git
gh auth status
```

### Hemligheten hittas inte

Kontrollera stavningen. Workflowet och GitHub-hemligheten måste båda använda `AZURE_WEBAPP_PUBLISH_PROFILE`.

```bash
gh secret list
```

### Deploy-steget rapporterar fel webbapp

Kontrollera att `AZURE_WEBAPP_NAME` är samma namn som i Azure:

```bash
az webapp show \
  --resource-group rg-clo25-steven \
  --name app-clo25-steven \
  --query defaultHostName \
  --output tsv
```

### Health checken misslyckas efter en lyckad deploy

Kontrollera endpointen och App Service-loggarna:

```bash
curl --include \
  https://app-clo25-steven.azurewebsites.net/health

az webapp log tail \
  --resource-group rg-clo25-steven \
  --name app-clo25-steven
```

Om appen bara behöver längre starttid kan du tillfälligt öka antalet försök:

```bash
MAX_ATTEMPTS=20 DELAY_SECONDS=15 ./scripts/health-check.sh \
  https://app-clo25-steven.azurewebsites.net/health
```

## Checklista för färdig labb

- [ ] Repot finns på GitHub.
- [ ] Resursgruppen, B1-planen och webbappen har byggts upp igen i West Europe.
- [ ] App Service-planen kör avsiktligt en instans.
- [ ] `/health` svarar med HTTP `200` i Azure.
- [ ] Appnamnet och det verkliga värdnamnet har lästs från Azure.
- [ ] SCM basic authentication är aktiverad, eller policybegränsningen och den manuella deploymenten är dokumenterade.
- [ ] `AZURE_WEBAPP_PUBLISH_PROFILE` finns som GitHub Actions-secret.
- [ ] `publish-profile.xml` är raderad och publish profiles skyddas av `.gitignore`.
- [ ] `scripts/health-check.sh` är körbart och returnerar rätt exitkod.
- [ ] En push till `main` startar workflowet.
- [ ] Workflowet återställer, bygger och testar Beacon.
- [ ] Workflowet publicerar och driftsätter Beacon till App Service.
- [ ] Health check-steget verifierar den driftsatta appen.
- [ ] En fullständig workflow-körning är grön.
- [ ] Deploymentstrategin är beskriven som in-place deployment och dess begränsningar är förklarade.
