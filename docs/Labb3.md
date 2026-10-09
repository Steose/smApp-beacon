# Labb 3: förbered automatiserad deployment av Beacon

## Mål

I den här tutorialen återskapar du Beacon i Azure, gör en manuell deployment och förbereder GitHub för framtida deployment via GitHub Actions. När du är klar finns en fungerande webbapp och en skyddad publish profile i GitHub Secrets.

## Förkunskaper

Du behöver:

- Beacon-projektet i ett GitHub-repo
- en `/health`-endpoint som svarar med HTTP-status `200`
- .NET 10 SDK, Git, Bash och Azure CLI
- GitHub CLI, `gh`, om du vill arbeta från terminalen
- en aktiv Azure-prenumeration
- behörighet att skapa Azure-resurser och GitHub Actions-hemligheter

Kontrollera verktygen och inloggningarna:

```bash
bash --version
az account show --output table
gh auth status
```

Logga in vid behov:

```bash
az login
gh auth login
```

Använd samma namn genom hela labben:

- resursgrupp: `rg-clo25-namn`
- App Service-plan: `asp-clo25-namn`
- webbapp: `app-clo25-namn`
- GitHub-hemlighet: `AZURE_WEBAPP_PUBLISH_PROFILE`

> **Varning:** Ersätt `namn` med ditt eget förnamn. Webbappens namn måste vara globalt unikt.

## Steg

### 1. Kontrollera hur Git-repot är anslutet

Visa Git-remoten:

```bash
git remote -v
```

Om adressen börjar med `git@` använder du SSH och kan fortsätta. Om adressen börjar med `https://` behöver GitHub-inloggningen rättigheten `workflow` för att pusha workflow-filer.

Kontrollera `Token scopes` i:

```bash
gh auth status
```

Om `workflow` saknas lägger du till rättigheten:

```bash
gh auth refresh -h github.com -s workflow
```

Kopiera engångskoden som visas, tryck Enter och godkänn sedan i webbläsaren. Låt Git använda samma inloggning som GitHub CLI:

```bash
gh auth setup-git
gh auth status
```

Kort kommandoförklaring:

- `gh auth refresh` uppdaterar rättigheterna för den befintliga GitHub-inloggningen.
- `-h github.com` väljer GitHub som värd.
- `-s workflow` begär rättigheten att hantera workflow-filer.
- `gh auth setup-git` konfigurerar Git att använda GitHub CLI:s autentisering.

### 2. Återskapa resursgruppen

```bash
az group create \
  --name rg-clo25-namn \
  --location westeurope
```

`az group create` skapar gruppen om den saknas och återanvänder den om den redan finns.

### 3. Återskapa App Service-planen

```bash
az appservice plan create \
  --name asp-clo25-namn \
  --resource-group rg-clo25-namn \
  --location westeurope \
  --sku B1 \
  --is-linux
```

Kort kommandoförklaring:

- `--sku B1` väljer Basic B1.
- `--is-linux` gör operativsystemet uttryckligt.
- Inget `--number-of-workers` anges, så planen får en instans.

En instans kostar minst men innebär att denna miljö inte kan använda en verklig rolling update över flera instanser.

### 4. Återskapa webbappen

```bash
az webapp create \
  --name app-clo25-namn \
  --resource-group rg-clo25-namn \
  --plan asp-clo25-namn \
  --runtime "DOTNETCORE:10.0"
```

`--plan` väljer App Service-planen och `--runtime` anger att appen ska köras med .NET 10.

### 5. Publicera appen lokalt

```bash
dotnet publish src/Beacon.Api \
  --configuration Release \
  --output artifacts/publish
```

Kontrollera att projektets `Target` från Labb 2 även skapade zip-paketet:

```bash
ls artifacts/
```

Förväntat innehåll:

```text
app.zip
publish/
```

Kort kommandoförklaring:

- `--configuration Release` bygger en version avsedd för drift.
- `--output artifacts/publish` samlar publicerade filer i en bestämd mapp.
- `app.zip` skapas av `ZipPublishOutput`-målet i `Beacon.Api.csproj`.

Om `app.zip` saknas ska `Target`-blocket ligga efter `PropertyGroup`, men före `</Project>`.

### 6. Gör en första manuell deployment

```bash
az webapp deploy \
  --resource-group rg-clo25-namn \
  --name app-clo25-namn \
  --src-path artifacts/app.zip \
  --type zip
```

`--src-path` pekar på paketet och `--type zip` anger distributionsformatet. Kommandot använder din aktuella Azure-inloggning.

### 7. Kontrollera att appen svarar

```bash
curl \
  -s \
  -o /dev/null \
  -w "%{http_code}\n" \
  https://app-clo25-namn.azurewebsites.net/health
```

Förväntat svar:

```text
200
```

Kort kommandoförklaring:

- `-s` döljer förloppsinformation.
- `-o /dev/null` kastar svarskroppen.
- `-w "%{http_code}\n"` skriver endast HTTP-statuskoden.

Svaret `000` är inte en HTTP-statuskod. Det betyder att `curl` inte fick något svar, ofta på grund av fel adress eller att appen inte är redo.

### 8. Läs appens exakta namn och adress

```bash
az webapp list \
  --resource-group rg-clo25-namn \
  --query "[].{Name:name, Address:defaultHostName}" \
  --output table
```

Förväntad struktur:

```text
Name            Address
--------------  ---------------------------------------
app-clo25-namn  app-clo25-namn.azurewebsites.net
```

Uttrycket i `--query` går igenom webbapparna, väljer `name` och `defaultHostName` och döper kolumnerna till `Name` och `Address`. Använd adressen som Azure returnerar eftersom nyare appar kan få ett extra suffix.

### 9. Aktivera basic authentication för SCM

En publish profile använder användarnamn och lösenord mot App Services deploymenttjänst, SCM. På nya appar är denna inloggning normalt avstängd.

```bash
az resource update \
  --resource-group rg-clo25-namn \
  --namespace Microsoft.Web \
  --resource-type basicPublishingCredentialsPolicies \
  --name scm \
  --parent sites/app-clo25-namn \
  --set properties.allow=true \
  --query properties \
  --output json
```

Förväntat svar:

```json
{
  "allow": true
}
```

Kort kommandoförklaring:

- `--namespace Microsoft.Web` väljer App Service-resurser.
- `--resource-type basicPublishingCredentialsPolicies` väljer policyn för publiceringsuppgifter.
- `--name scm` väljer deploymenttjänsten.
- `--parent sites/app-clo25-namn` kopplar policyn till rätt webbapp.
- `--set properties.allow=true` tillåter publish profile-inloggning.

SCM betyder Source Control Management. Appen betjänar användare på `app-clo25-namn.azurewebsites.net`, medan deployment, loggar och administrationsverktyg använder `app-clo25-namn.scm.azurewebsites.net`.

> **Säkerhet:** Basic authentication är enklare men svagare än en separat identitet med federerad inloggning. Här används den medvetet för övningen.

### 10. Använd den manuella vägen om policyn nekar ändringen

Om föregående kommando ger `RequestDisallowedByPolicy` tillåter prenumerationen inte basic authentication. Hoppa då över stegen för publish profile och behåll deploymenten som ett manuellt steg:

```bash
dotnet publish src/Beacon.Api \
  --configuration Release \
  --output artifacts/publish

az webapp deploy \
  --resource-group rg-clo25-namn \
  --name app-clo25-namn \
  --src-path artifacts/app.zip \
  --type zip
```

Det fungerar eftersom `az webapp deploy` kan använda identiteten från `az login` i stället för publish profile-uppgifter.

Dokumentera i så fall:

1. att deploymenten körs manuellt med `az webapp deploy`
2. att prenumerationen blockerar basic authentication
3. att nästa steg vore en service principal eller federerad GitHub-inloggning

### 11. Hämta publish-profilen

Om basic authentication är tillåten hämtar du profilen till en tillfällig lokal fil:

```bash
az webapp deployment list-publishing-profiles \
  --name app-clo25-namn \
  --resource-group rg-clo25-namn \
  --xml > publish-profile.xml
```

Tecknet `>` skickar kommandots XML-utdata till filen i stället för till terminalen.

Kontrollera början av filen:

```bash
head -c 70 publish-profile.xml
```

Du ska se XML-data som innehåller rätt appnamn:

```xml
<publishData><publishProfile profileName="app-clo25-namn - Web Deploy"
```

> **Varning:** Filen innehåller inloggningsuppgifter och ska behandlas som ett lösenord. Den får aldrig committas.

### 12. Lägg till profilen som en GitHub-hemlighet

```bash
gh secret set AZURE_WEBAPP_PUBLISH_PROFILE < publish-profile.xml
gh secret list
```

Förväntad lista:

```text
NAME                          UPDATED
AZURE_WEBAPP_PUBLISH_PROFILE  less than a minute ago
```

Kort kommandoförklaring:

- `< publish-profile.xml` använder hela filen som indata.
- `gh secret set` lagrar värdet krypterat för repots GitHub Actions.
- `gh secret list` visar hemlighetens namn, men aldrig dess värde.

Utan GitHub CLI gör du samma sak via repots **Settings → Secrets and variables → Actions → New repository secret**. Använd exakt namnet `AZURE_WEBAPP_PUBLISH_PROFILE` och markera hela XML-filen när värdet kopieras.

### 13. Radera och ignorera den lokala profilen

Radera filen direkt när hemligheten har skapats:

```bash
rm publish-profile.xml
```

Skydda repot mot framtida nedladdningar:

```bash
echo "publish-profile.xml" >> .gitignore
echo "*.publishsettings" >> .gitignore
```

Den första regeln ignorerar filnamnet från labben. Den andra ignorerar filformatet som Azure och Visual Studio ofta använder för publish profiles.

> **Varning:** Om en hemlighet redan har committats räcker det inte att radera filen. Uppgifterna måste återkallas eftersom de finns kvar i Git-historiken.

### 14. Frivillig utmaning: automatisera hemligheten

Skapa senare ett `scripts/refresh-secret.sh` som:

1. tar appnamn och resursgrupp som argument
2. hämtar publish-profilen
3. uppdaterar GitHub-hemligheten
4. alltid tar bort den lokala filen
5. avslutas med en felkod som inte är noll om något steg misslyckas

Källfilen beskriver kraven men innehåller ingen färdig implementation.

## Verifiering

```bash
curl -s -o /dev/null -w "%{http_code}\n" \
  https://app-clo25-namn.azurewebsites.net/health

gh secret list

git status --short
```

Tutorialen är klar när:

- `/health` svarar med `200`
- Azure visar rätt appnamn och adress
- SCM-policyn visar `"allow": true`, om prenumerationen tillåter det
- `AZURE_WEBAPP_PUBLISH_PROFILE` visas i `gh secret list`
- `publish-profile.xml` inte finns lokalt och inte visas i Git
- `.gitignore` skyddar både `publish-profile.xml` och `*.publishsettings`

Om prenumerationen blockerar basic authentication är den manuella deploymenten och den dokumenterade begränsningen det förväntade resultatet.

## Städning

Om du inte behöver Azure-miljön i nästa övning tar du bort resursgruppen för att stoppa kostnaden:

```bash
az group delete \
  --name rg-clo25-namn \
  --yes \
  --no-wait
```

Kontrollera borttagningen:

```bash
az group exists --name rg-clo25-namn
```

Förväntat svar när borttagningen är klar:

```text
false
```

Behåll GitHub-hemligheten endast om samma webbapp ska användas igen. En publish profile hör till den specifika appen och blir oanvändbar när resursen tas bort eller uppgifterna återkallas.
