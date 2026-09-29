# Övning 9: förbered Beacon för containerdrift

## Mål

Du ska välja och motivera tre skalningsvärden, ta fram rätt projektsökväg och DLL-namn samt se vad en publicerad .NET-app innehåller. Om Docker finns kan du också bygga och prova containern lokalt.

## Förkunskaper

Du behöver Beacon-repot, .NET 10 SDK och ett fungerande `scripts/health-check.sh`. Kör kommandona från repots rot. Docker behövs bara för det frivilliga sista steget. Övningen använder inga Azure-resurser.

## Steg

### 1. Bedöm skalningsregeln

Läs följande Bicep-block:

```bicep
scale: {
  minReplicas: 0
  maxReplicas: 1
  rules: [
    {
      name: 'http-scaling'
      http: {
        metadata: { concurrentRequests: '1' }
      }
    }
  ]
}
```

`minReplicas: 0` låter appen skala till noll när den inte används, vilket kan ge kallstart vid nästa anrop. `maxReplicas: 1` hindrar utskalning till fler än en replik. Tröskeln `concurrentRequests: '1'` är mycket låg men kan inte ge fler repliker när max redan är ett.

Välj egna värden för `minReplicas`, `maxReplicas` och `concurrentRequests`. Skriv ett konkret skäl för varje värde i `docs/TUTORIAL.md`: väg snabb första respons mot kostnad, och möjlig samtidighet mot tillgänglig kapacitet. Värdena ska användas i nästa labbs Bicep-mall.

### 2. Hämta Dockerfilens två projektvärden

Läs `.csproj`-sökvägen ur det fungerande workflowet:

```bash
rg -n 'csproj' .github/workflows/deploy.yml
```

Om workflowet inte nämner en projektfil, hitta den i repot:

```bash
rg --files -g '*.csproj'
```

Välj webbprojektet, inte testprojektet. Kontrollera om det har ett eget assembly-namn:

```bash
rg -n 'AssemblyName' src/Beacon.Api/Beacon.Api.csproj
```

Ingen träff är normalt: då blir `Beacon.Api.csproj` till `Beacon.Api.dll`. Om `AssemblyName` finns använder du dess värde plus `.dll`. Skriv ner båda värdena i `docs/TUTORIAL.md`, till exempel:

```text
csproj: ./src/Beacon.Api/Beacon.Api.csproj
dll:    Beacon.Api.dll
```

Sökvägen ska senare användas i Dockerfilens `dotnet restore` och `dotnet publish`; DLL-namnet ska användas i `ENTRYPOINT`.

### 3. Granska publiceringsresultatet

Publicera appen och titta på filerna:

```bash
dotnet publish ./src/Beacon.Api/Beacon.Api.csproj \
  --configuration Release \
  --output ./artifacts/publish

ls artifacts/publish
du -sh artifacts/publish
du -sh .
```

I `artifacts/publish` ska du se körbara DLL:er och nödvändig konfiguration, men inte källkod, `.csproj`, Git-historik eller byggmapparna `bin` och `obj`. Det är detta publicerade resultat som kopieras till Dockerfilens andra, mindre runtime-steg. Storleksjämförelsen visar skillnaden mellan publiceringsresultatet och hela repot.

### 4. Bygg och kör lokalt (frivilligt)

Har du Docker igång, skapa `src/Beacon.Api/Dockerfile` med sökvägen och DLL-namnet från steg 2:

```dockerfile
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
ARG PROJECT=src/Beacon.Api/Beacon.Api.csproj
WORKDIR /src
COPY . .
RUN dotnet restore ./$PROJECT
RUN dotnet publish ./$PROJECT --configuration Release --output /app/publish

FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS final
WORKDIR /app
COPY --from=build /app/publish .
ENTRYPOINT ["dotnet", "Beacon.Api.dll"]
```

Första `FROM` använder SDK:n för att bygga. Andra `FROM` använder bara ASP.NET-runtime och får enbart de publicerade filerna via `COPY --from=build`.

Skapa `.dockerignore` i repots rot, eftersom repots rot är byggkontext:

```dockerignore
**/bin/
**/obj/
**/publish/
artifacts/
.git/
.github/
infra/
azure-credentials.json
publish-profile.xml
*.publishsettings
```

Bygg och starta sedan containern från repots rot:

```bash
docker build --file src/Beacon.Api/Dockerfile --tag beacon:local .
docker run --rm --publish 8080:8080 beacon:local
```

Läs `Now listening on` i containerloggen. Den faktiska porten ska användas som `targetPort` i nästa labb; för denna .NET-image är den normalt `8080`. Verifiera från en annan terminal:

```bash
./scripts/health-check.sh http://localhost:8080/health
```

Stoppa containern med Ctrl+C. Om kontrollen lyckas kan du spara de nya filerna:

```bash
git add src/Beacon.Api/Dockerfile .dockerignore
git commit -m "Add Dockerfile for the container track"
```

## Verifiering

Övningen är klar när `docs/TUTORIAL.md` innehåller tre motiverade skalningsvärden samt korrekt `.csproj`-sökväg och DLL-namn. Du ska också kunna beskriva vad `artifacts/publish` innehåller. Om du gjorde Docker-steget ska `/health` svara med HTTP `200` på `localhost:8080`.

## Städning

Stoppa en körande container med Ctrl+C. Publiceringsfilerna är genererade och kan tas bort när du granskat dem:

```bash
rm -r artifacts/publish
rm -f artifacts/app.zip
```

Kör borttagningskommandona endast från repots rot och bara om du inte behöver filerna för en pågående deployment. Inga Azure-resurser behöver städas.
