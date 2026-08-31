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

## Beslut jag tagit

Jag valde att bygga Beacon eftersom en enkel tjänst för att övervaka en applikations status passar bra för att lära sig hur skalbara molnapplikationer fungerar. Idén gör det möjligt att börja med tydliga endpoints för hälso- och systeminformation och sedan bygga vidare med fler funktioner under kursens gång.
