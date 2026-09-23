# Labb 1: skapa och testa Beacon

## Mål

I den här tutorialen skapar du en minimal webbapp i .NET 10 med endpoints för status och hälsokontroll. När du är klar finns appen och två integrationstester i ett lokalt Git-repo.

## Förkunskaper

Du behöver:

- grundläggande vana vid en terminal
- .NET 10 SDK
- Git
- en editor som Visual Studio Code, Visual Studio eller Rider
- ett terminalskal som Bash, Zsh, Git Bash eller WSL

Kontrollera installationerna:

```bash
dotnet --version
git --version
```

`dotnet --version` ska visa version 10.

## Steg

### 1. Skapa mappen och Git-repot

Skapa projektmappen och gå in i den:

```bash
mkdir beacon
cd beacon
```

Initiera ett Git-repo:

```bash
git init
```

Tutorialen använder namnet `Beacon` för produkten och `Beacon.Api` för webbprojektet. Om du väljer andra namn måste du använda dem konsekvent även i senare pipelines och Dockerfiler.

### 2. Lägg till `.gitignore` och gör första commiten

Skapa .NET:s standardfil för ignorerade filer:

```bash
dotnet new gitignore
```

Kontrollera att en framtida buildfil under `bin/` kommer att ignoreras:

```bash
git check-ignore -v src/Beacon.Api/bin/Debug/net10.0/Beacon.Api.dll
```

Resultatet ska peka på en `[Bb]in/`-regel i `.gitignore`. Sökvägen behöver inte finnas; kommandot visar vilken regel som skulle gälla om filen skapades.

Gör den första commiten innan några genererade buildfiler hinner läggas till:

```bash
git add .gitignore
git commit -m "Initial commit"
```

> **Tips:** `git check-ignore -v <sökväg>` visar varför en fil inte syns i `git status`.

### 3. Skapa lösningen och webbprojektet

Skapa lösningen:

```bash
dotnet new sln --name Beacon
```

.NET 10 skapar normalt `Beacon.slnx`. Det är lösningsfilen som samlar appen och testerna.

Skapa en minimal webbapp:

```bash
dotnet new web --output src/Beacon.Api --name Beacon.Api
```

Lägg till projektet i lösningen:

```bash
dotnet sln add src/Beacon.Api/Beacon.Api.csproj
```

Kontrollera att projektet går att bygga:

```bash
dotnet build
```

Förväntat slutresultat:

```text
Build succeeded
```

Exakt tidsåtgång och övriga rader kan variera.

### 4. Implementera appens endpoints

Ersätt innehållet i `src/Beacon.Api/Program.cs` med:

```csharp
var builder = WebApplication.CreateBuilder(args);
var app = builder.Build();

app.MapGet("/", () => new
{
    app = "Beacon",
    status = "running"
});

// Health check. Used by App Service, health-check.sh and the container.
// Do not remove or change this route.
app.MapGet("/health", () => Results.Ok("OK"));

app.Run();

// Makes Program visible to the test project.
public partial class Program { }
```

Kort kodförklaring:

- `WebApplication.CreateBuilder(args)` skapar och konfigurerar webbappen.
- `builder.Build()` bygger appen så att endpoints kan registreras.
- `MapGet("/", ...)` kopplar ett GET-anrop till rotadressen. Objektet omvandlas automatiskt till JSON.
- `MapGet("/health", ...)` skapar hälsokontrollen och returnerar HTTP-status `200 OK`.
- `app.Run()` startar appen och börjar ta emot anrop.
- `public partial class Program { }` gör `Program` tillgänglig för integrationstesterna.

> **Varning:** Ta inte bort `/health` och ändra inte sökvägen. Senare labbar och molntjänster använder den för att kontrollera att appen fungerar.

### 5. Använd fasta lokala portar

Öppna `src/Beacon.Api/Properties/launchSettings.json` och ersätt innehållet med:

```json
{
  "$schema": "https://json.schemastore.org/launchsettings.json",
  "profiles": {
    "http": {
      "commandName": "Project",
      "dotnetRunMessages": true,
      "launchBrowser": false,
      "applicationUrl": "http://localhost:5001",
      "environmentVariables": {
        "ASPNETCORE_ENVIRONMENT": "Development"
      }
    },
    "https": {
      "commandName": "Project",
      "dotnetRunMessages": true,
      "launchBrowser": false,
      "applicationUrl": "https://localhost:7001;http://localhost:5001",
      "environmentVariables": {
        "ASPNETCORE_ENVIRONMENT": "Development"
      }
    }
  }
}
```

Appen använder nu port `5001` för HTTP och `7001` för HTTPS. `launchBrowser` är avstängt eftersom appen ska kunna startas utan att öppna en webbläsare.

Kort kodförklaring:

- `commandName: "Project"` startar det aktuella .NET-projektet.
- `applicationUrl` anger vilka lokala adresser appen ska lyssna på.
- `ASPNETCORE_ENVIRONMENT: "Development"` aktiverar utvecklingsmiljön.
- `launchBrowser: false` förhindrar att en webbläsarflik öppnas automatiskt.

Om du vill använda HTTPS lokalt behöver datorn ett betrott utvecklingscertifikat:

```bash
dotnet dev-certs https --trust
```

### 6. Kör och prova appen

Starta HTTP-profilen:

```bash
dotnet run --project src/Beacon.Api
```

Förväntad information:

```text
Now listening on: http://localhost:5001
Application started. Press Ctrl+C to shut down.
```

Låt appen fortsätta köra och öppna en andra terminal i samma projektmapp. Testa rot-endpointen:

```bash
curl http://localhost:5001/
```

Förväntat svar:

```json
{"app":"Beacon","status":"running"}
```

Kontrollera endast statuskoden från `/health`:

```bash
curl -s -o /dev/null -w "%{http_code}\n" \
  http://localhost:5001/health
```

Förväntat svar:

```text
200
```

För att köra med HTTPS-profilen använder du:

```bash
dotnet run --project src/Beacon.Api --launch-profile https
```

Stoppa appen med Ctrl+C när kontrollen är klar.

### 7. Lägg till en HTTP-requests-fil

Skapa `requests.http` i repots rotmapp:

```http
@host = http://localhost:5001

### Root - returns a small JSON object
GET {{host}}/

### Health - should always return 200 OK
GET {{host}}/health
```

Visual Studio och Rider har inbyggt stöd för formatet. I Visual Studio Code kan tillägget REST Client användas. Starta appen och välj **Send Request** ovanför respektive `GET`-rad för att se svaret.

Variabeln `host` gör att samma fil senare kan användas mot Azure genom att endast adressen på första raden ändras.

Kort kodförklaring:

- `@host` sparar serveradressen i en återanvändbar variabel.
- `{{host}}` ersätts med variabelns värde när anropet skickas.
- `###` skiljer anropen åt i filen.
- `GET` anger att klienten ska hämta information från endpointen.

### 8. Skapa testprojektet

Skapa ett xUnit-projekt:

```bash
dotnet new xunit --output tests/Beacon.Tests --name Beacon.Tests
```

Lägg till testprojektet i lösningen:

```bash
dotnet sln add tests/Beacon.Tests/Beacon.Tests.csproj
```

Lägg till en projektreferens till webbappen:

```bash
dotnet add tests/Beacon.Tests/Beacon.Tests.csproj \
  reference src/Beacon.Api/Beacon.Api.csproj
```

Installera paketet som kan starta webbappen inuti testerna:

```bash
dotnet add tests/Beacon.Tests/Beacon.Tests.csproj \
  package Microsoft.AspNetCore.Mvc.Testing
```

Ta bort mallens exempeltest:

```bash
rm tests/Beacon.Tests/UnitTest1.cs
```

> **Varning:** Ett `\` i slutet av en kommandorad betyder att kommandot fortsätter på nästa rad. Det får inte finnas mellanslag efter tecknet.

### 9. Skriv integrationstesterna

Skapa `tests/Beacon.Tests/HealthEndpointTests.cs`:

```csharp
using System.Net;
using Microsoft.AspNetCore.Mvc.Testing;

namespace Beacon.Tests;

public class HealthEndpointTests : IClassFixture<WebApplicationFactory<Program>>
{
    private readonly WebApplicationFactory<Program> _factory;

    public HealthEndpointTests(WebApplicationFactory<Program> factory)
    {
        _factory = factory;
    }

    [Fact]
    public async Task Health_WhenRequested_ReturnsOk()
    {
        var client = _factory.CreateClient();

        var response = await client.GetAsync("/health");

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
    }

    [Fact]
    public async Task Root_WhenRequested_ReturnsOk()
    {
        var client = _factory.CreateClient();

        var response = await client.GetAsync("/");

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
    }
}
```

Kort kodförklaring:

- `IClassFixture<WebApplicationFactory<Program>>` skapar en testversion av appen i minnet.
- `_factory.CreateClient()` ger testet en HTTP-klient kopplad till testappen.
- `GetAsync(...)` skickar ett riktigt GET-anrop utan att du startar servern manuellt.
- `Assert.Equal(...)` kontrollerar att svaret är `200 OK`.
- `[Fact]` markerar en metod som ett xUnit-test.

Testnamnen följer mönstret `Enhet_Scenario_FörväntatUtfall`. Exempelvis betyder `Health_WhenRequested_ReturnsOk` att health-endpointen ska svara OK när den anropas. Tydliga namn gör fel lättare att förstå i testresultatet.

`using Xunit;` behöver inte skrivas i filen eftersom projektfilen innehåller en global xUnit-import.

Kör testerna:

```bash
dotnet test
```

Förväntat resultat är två godkända tester och inga misslyckade.

Kontrollera även att testet kan upptäcka ett fel:

1. Kommentera tillfälligt bort raden som registrerar `/health` i `Program.cs`.
2. Kör `dotnet test` och kontrollera att health-testet misslyckas.
3. Återställ raden.
4. Kör `dotnet test` igen och kontrollera att båda testerna lyckas.

## Verifiering

Kör en fullständig slutkontroll:

```bash
dotnet build
dotnet test
```

Tutorialen är klar när:

- bygget lyckas utan fel
- två tester är godkända och inga har misslyckats
- `curl http://localhost:5001/` returnerar Beacons JSON-svar
- `/health` returnerar HTTP-status `200`
- `requests.http` kan anropa både `/` och `/health`

## Städning

Labb 1 skapar inga molnresurser och medför därför inga molnkostnader. Stoppa en eventuell lokal app med Ctrl+C.
