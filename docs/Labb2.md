# Labb 2: driftsätt och skala Beacon i Azure

## Mål

I den här tutorialen publicerar du Beacon till Azure App Service, skalar appen från en till tre instanser och aktiverar plattformens health check. När du är klar har du verifierat både appens svar och dess skalningskonfiguration innan resurserna tas bort.

## Förkunskaper

Du behöver:

- Beacon-projektet från Labb 1 i ett Git-repo
- ett webbprojekt som heter `Beacon.Api`
- en fungerande `/health`-endpoint
- .NET 10 SDK
- Azure CLI
- en aktiv Azure-prenumeration med rätt att skapa resurser
- Bash, Zsh, Git Bash eller WSL

Kontrollera att `/health` finns i `src/Beacon.Api/Program.cs`:

```csharp
app.MapGet("/health", () => Results.Ok("OK"));
```

`MapGet` kopplar ett GET-anrop till `/health`. `Results.Ok("OK")` returnerar svaret `OK` med HTTP-status `200`, vilket Azure använder för att bedöma om appen fungerar.

Kontrollera Azure-inloggningen:

```bash
az account show --output table
```

Logga in om kommandot misslyckas:

```bash
az login
```

Alla exempel använder följande namn:

- resursgrupp: `rg-clo25-namn`
- App Service-plan: `asp-clo25-namn`
- webbapp: `app-clo25-namn`
- region: `westeurope`

> **Varning:** Ersätt `namn` med ditt eget förnamn i samtliga kommandon. Använd samma stavning genom hela kursen. Webbappens namn måste dessutom vara globalt unikt.

## Steg

### 1. Ställ dig i repots rotmapp

Alla kommandon ska köras från mappen som innehåller lösningen:

```bash
ls
```

Du ska se `src/`, `tests/` och `Beacon.slnx` eller `Beacon.sln`. Om du ser `Beacon.Api.csproj` och `Program.cs` står du sannolikt i projektmappen. Gå då upp till repots rot:

```bash
cd ../..
```

### 2. Kontrollera eller skapa resursgruppen

Kontrollera om resursgruppen redan finns:

```bash
az group exists --name rg-clo25-namn
```

Om svaret är `false`, skapa den i West Europe:

```bash
az group create \
  --name rg-clo25-namn \
  --location westeurope
```

Resursgruppen måste finnas innan App Service-resurserna skapas. Ett felstavat gruppnamn ger annars `ResourceGroupNotFound`.

Kort kodförklaring:

- `az group exists` kontrollerar gruppen utan att ändra något.
- `--name` anger resursgruppens namn.
- `--location westeurope` placerar nya resurser i regionen West Europe.

### 3. Skapa App Service-planen

Planen innehåller de beräkningsresurser som appen ska köras på:

```bash
az appservice plan create \
  --name asp-clo25-namn \
  --resource-group rg-clo25-namn \
  --location westeurope \
  --sku B1 \
  --is-linux
```

Kort kodförklaring:

- `az appservice plan create` skapar beräkningsmiljön som webbappen ska använda.
- `--sku B1` väljer pris- och kapacitetsnivån Basic B1.
- `--is-linux` gör planen till en Linux-plan.
- Planen får en instans eftersom inget annat antal anges.

### 4. Skapa webbappen

Koppla webbappen till planen och välj .NET 10:

```bash
az webapp create \
  --name app-clo25-namn \
  --resource-group rg-clo25-namn \
  --plan asp-clo25-namn \
  --runtime "DOTNETCORE:10.0"
```

Om namnet är upptaget lägger du till initialer eller siffror och använder det nya namnet i alla senare kommandon.

Kort kodförklaring:

- `--plan` kopplar webbappen till App Service-planen.
- `--runtime "DOTNETCORE:10.0"` väljer .NET 10 som körmiljö.
- `--name` blir en del av den publika adressen och måste därför vara globalt unikt.

### 5. Lägg till automatisk zip-paketering

`az webapp deploy` behöver ett färdigbyggt zip-paket. Lägg till följande mål strax före `</Project>` i `src/Beacon.Api/Beacon.Api.csproj`:

```xml
<!-- Packar publiceringen till app.zip, bredvid publiceringsmappen -->
<Target Name="ZipPublishOutput" AfterTargets="Publish">
  <ZipDirectory SourceDirectory="$(PublishDir)"
                DestinationFile="$(PublishDir)../app.zip"
                Overwrite="true" />
</Target>
```

Paketeringen körs av .NET:s byggsystem och fungerar därför på macOS, Linux och Windows utan separata zip-verktyg.

Kort kodförklaring:

- `AfterTargets="Publish"` kör målet automatiskt efter varje publicering.
- `$(PublishDir)` är mappen där `dotnet publish` placerar appen.
- `DestinationFile` skapar `app.zip` bredvid publiceringsmappen.
- `Overwrite="true"` ersätter ett äldre paket vid nästa publicering.

### 6. Publicera och kontrollera paketet

Bygg en Release-publicering:

```bash
dotnet publish src/Beacon.Api \
  --configuration Release \
  --output artifacts/publish
```

`--configuration Release` skapar en optimerad version för drift. `--output` samlar de publicerade filerna i `artifacts/publish`.

Kontrollera resultatet:

```bash
ls artifacts/
```

Du ska se:

```text
app.zip
publish/
```

Mappen `artifacts/` finns redan i den `.gitignore` som skapades i Labb 1. Kontrollera att byggresultatet inte visas av Git:

```bash
git status --short
```

Om `app.zip` saknas kontrollerar du att `Target`-blocket ligger utanför `PropertyGroup`, men före `</Project>`, och kör sedan `dotnet publish` igen.

### 7. Driftsätt appen

Skicka paketet till App Service:

```bash
az webapp deploy \
  --resource-group rg-clo25-namn \
  --name app-clo25-namn \
  --src-path artifacts/app.zip \
  --type zip
```

Deploymenten tar normalt en eller två minuter. Ett lyckat resultat innehåller:

```text
"status": "RuntimeSuccessful"
```

Paketet är redan byggt av `dotnet publish`, så Azure behöver inte bygga källkoden under deploymenten.

Kort kodförklaring:

- `--src-path` pekar på det färdigbyggda zip-paketet.
- `--type zip` talar om vilket distributionsformat som skickas.
- `--resource-group` och `--name` identifierar webbappen som ska uppdateras.

### 8. Verifiera den driftsatta appen

Kontrollera `/health` över HTTPS:

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

Flaggorna gör kontrollen enkel att läsa:

- `-s` döljer förloppsinformation.
- `-o /dev/null` kastar själva svarskroppen.
- `-w "%{http_code}\n"` skriver endast HTTP-statuskoden.

Azure visar ofta värdnamnet utan protokoll. Använd alltid `https://` framför `azurewebsites.net`-adressen.

### 9. Läs av nuvarande skalning

Visa planens prisnivå och antal instanser:

```bash
az appservice plan list \
  --resource-group rg-clo25-namn \
  --query "[].{Name:name, Tier:sku.name, Instances:sku.capacity}" \
  --output table
```

Förväntat utgångsläge:

```text
Name            Tier    Instances
--------------  ------  ---------
asp-clo25-namn  B1      1
```

Kort kodförklaring:

- `[]` går igenom varje plan i resultatlistan.
- `{Name:name, Tier:sku.name, Instances:sku.capacity}` väljer tre fält och ger dem tydliga kolumnnamn.
- Punkten i `sku.name` går till ett underliggande fält i JSON-svaret.
- `--output table` visar resultatet som en tabell i stället för fullständig JSON.

### 10. Skala ut till tre instanser

Ändra App Service-planens worker-antal:

```bash
az appservice plan update \
  --name asp-clo25-namn \
  --resource-group rg-clo25-namn \
  --number-of-workers 3
```

Appen körs nu i tre instanser och App Service fördelar inkommande trafik mellan dem.

`--number-of-workers 3` anger hur många instanser planen ska använda. Eftersom apparna ligger på planen påverkar skalningen planens beräkningskapacitet.

### 11. Verifiera utskalningen

Kör samma avläsning igen:

```bash
az appservice plan list \
  --resource-group rg-clo25-namn \
  --query "[].{Name:name, Tier:sku.name, Instances:sku.capacity}" \
  --output table
```

Kolumnen `Instances` ska nu visa `3`:

```text
Name            Tier    Instances
--------------  ------  ---------
asp-clo25-namn  B1      3
```

Tre är ett litet demonstrationsvärde som visar utskalning och ger flera instanser för redundans.

### 12. Aktivera App Service health check

Du kan först hitta inställningen i Azure-portalen:

1. Öppna webbappen.
2. Välj **Monitoring → Health check**.
3. Aktivera funktionen.
4. Ange sökvägen `/health`.
5. Spara.

Samma inställning kan göras från terminalen:

```bash
az webapp config set \
  --resource-group rg-clo25-namn \
  --name app-clo25-namn \
  --generic-configurations health_check_path="/health"
```

> **Varning:** Här ska parametern skrivas `health_check_path` med understreck. Formen `healthCheckPath` kan ge ett lyckat kommando utan att inställningen faktiskt ändras.

`--generic-configurations` skriver en inställning direkt i webbappens konfiguration. Värdet `/health` måste motsvara endpointen i `Program.cs`.

### 13. Verifiera health check-inställningen

Läs tillbaka värdet från Azure:

```bash
az webapp show \
  --resource-group rg-clo25-namn \
  --name app-clo25-namn \
  --query siteConfig.healthCheckPath \
  --output tsv
```

Förväntat svar:

```text
/health
```

`--query siteConfig.healthCheckPath` läser endast health check-sökvägen och `--output tsv` visar värdet utan JSON-format eller citattecken.

App Service anropar nu endpointen regelbundet. Om en instans slutar svara kan plattformen ta den ur trafikrotationen och skicka trafiken till friska instanser.

### 14. Prova en omstart (frivilligt)

Starta om webbappen:

```bash
az webapp restart \
  --resource-group rg-clo25-namn \
  --name app-clo25-namn
```

Ladda om appens adress under omstarten och observera om något avbrott märks. Flera instanser och en health check förbättrar tillgängligheten, men garanterar inte ensamma en helt avbrottsfri deploymentstrategi.

## Frivillig fördjupning: autoscale

Basic B1 stöder inte de autoscale-regler som används här. Uppgradera därför tillfälligt till Premium v3 och behåll samtidigt tre instanser:

```bash
az appservice plan update \
  --name asp-clo25-namn \
  --resource-group rg-clo25-namn \
  --sku P0V3 \
  --number-of-workers 3
```

Om `P0V3` inte stöds på planens maskinpark kan du använda `S1`.

Öppna App Service-planens **Scale out**-inställning i portalen, välj regelbaserad skalning och skapa följande regler:

| Riktning | Mätvärde | Villkor | Varaktighet | Åtgärd | Cooldown |
|---|---|---|---|---|---|
| Ut | CPU Percentage | större än 70 % | 5 minuter | öka med 1 | 5 minuter |
| In | CPU Percentage | mindre än 30 % | 10 minuter | minska med 1 | 5 minuter |

Ange instansgränserna:

| Inställning | Värde |
|---|---:|
| Minimum | 2 |
| Maximum | 3 |
| Default | 2 |

Minimum två bevarar redundans. Glappet mellan 70 och 30 procent samt den längre inskalningstiden minskar risken för att kapaciteten pendlar upp och ned vid korta lastförändringar.

När försöket är klart väljer du åter **Manual scale**, sätter antalet till tre och skalar omedelbart tillbaka till B1:

```bash
az appservice plan update \
  --name asp-clo25-namn \
  --resource-group rg-clo25-namn \
  --sku B1 \
  --number-of-workers 3
```

Premium kostar betydligt mer än B1, så lämna inte planen på den högre nivån efter övningen.

## Felsökning

| Fel | Orsak | Åtgärd |
|---|---|---|
| `dotnet publish` hittar inte projektet | Du står inte i repots rot | Kör `ls`; gå vid behov upp med `cd ../..` |
| `ResourceGroupNotFound` | Gruppen saknas eller har fel namn | Kör `az group exists` och skapa gruppen i steg 2 |
| Webbappens namn är upptaget | Appnamnet används globalt som URL | Lägg till initialer eller siffror och använd det nya namnet konsekvent |
| Runtime-fel | Planens OS eller runtime är fel | Kontrollera planen och kör `az webapp list-runtimes --os linux --output table` |
| `artifacts/app.zip` saknas | Paketeringsmålet kördes inte | Kontrollera `Target`-blocket i `.csproj` och publicera igen |
| Health check-värdet är tomt | Inställningsnamnet skrevs fel | Använd `health_check_path="/health"` eller konfigurera portalen |

Kontrollera planens operativsystem om appen inte startar:

```bash
az appservice plan list \
  --resource-group rg-clo25-namn \
  --query "[].{Name:name, Kind:kind}" \
  --output table
```

Värdet ska indikera Linux.

## Verifiering

Kör följande slutkontroller innan resurserna tas bort:

```bash
curl -s -o /dev/null -w "%{http_code}\n" \
  https://app-clo25-namn.azurewebsites.net/health

az appservice plan list \
  --resource-group rg-clo25-namn \
  --query "[].{Name:name, Tier:sku.name, Instances:sku.capacity}" \
  --output table

az webapp show \
  --resource-group rg-clo25-namn \
  --name app-clo25-namn \
  --query siteConfig.healthCheckPath \
  --output tsv
```

Tutorialen är klar när:

- `/health` svarar med HTTP-status `200`
- planen använder B1 och visar tre instanser
- health check-sökvägen är `/health`
- `artifacts/` inte visas i `git status`
- du har dokumenterat resursgruppen, appnamnet, vald nivå och varför tre instanser används

## Städning

Azure-resurserna kostar pengar per timme. Lista först vad resursgruppen innehåller:

```bash
az resource list \
  --resource-group rg-clo25-namn \
  --query "[].{Name:name, Type:type}" \
  --output table
```

Kontrollera gruppnamnet noggrant och ta sedan bort hela resursgruppen:

```bash
az group delete \
  --name rg-clo25-namn \
  --yes \
  --no-wait
```

Kort kodförklaring:

- `--yes` bekräftar borttagningen utan en extra fråga.
- `--no-wait` lämnar tillbaka terminalen medan Azure fortsätter borttagningen i bakgrunden.

Det finns ingen papperskorg för borttagna Azure-resurser. Källkoden finns däremot kvar i Git och resurserna kan skapas på nytt.

Kontrollera borttagningen:

```bash
az group exists --name rg-clo25-namn
```

Förväntat svar när borttagningen är färdig:

```text
false
```

Om svaret fortfarande är `true`, vänta någon minut och kontrollera igen. `--no-wait` gör att borttagningen fortsätter i bakgrunden.

Att endast stoppa webbappen minskar inte kostnaden. Du betalar för App Service-planens instanser även när appen är stoppad, så resursgruppen ska tas bort när labbmiljön inte längre behövs.
