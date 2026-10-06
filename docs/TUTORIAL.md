# Tutorial

## Vad appen är

**Beacon är en enkel .NET 10-webbapp som visar appens status och har en hälsokontroll. Den körs i Azure och använder automatiserad deployment, skalning, containrar och säker hantering av hemligheter.**

## Så kör du den lokalt

### Steg 1

**Skapar du en minimal webbapp i .NET 10 med endpoints för status och hälsokontroll. När du är klar finns appen och två integrationstester i ett lokalt Git-repo. [`docs/Labb1.md`](../docs/Labb1.md)**

### Steg 2

**I den här steg publicerar du Beacon till Azure App Service, skalar appen från en till tre instanser och aktiverar plattformens health check. När du är klar har du verifierat både appens svar och dess skalningskonfiguration innan resurserna tas bort. [`docs/Labb2.md`](../docs/Labb2.md)**

### Steg 3

**I den här steg återskapar du Beacon i Azure, gör en manuell deployment och förbereder GitHub för framtida deployment via GitHub Actions. När du är klar finns en fungerande webbapp och en skyddad publish profile i GitHub Secrets. [`docs/Labb3.md`](../docs/Labb3.md)**

### Steg 4

**I den här steg beskriver du Beacons App Service-plan och webbapp som Infrastructure as Code med Bicep. Du validerar och driftsätter mallen, verifierar att den är idempotent och kopplar deploymenten till ditt arbetsflöde antingen automatiskt eller via ett dokumenterat lokalt skript. [`docs/Labb4.md`](../docs/Labb4.md)**

### Steg 5

**Du ska paketera Beacon som en container, lagra imagen i ett eget Azure Container Registry (ACR) och köra den i Azure Container Apps. Efter labben kan en push bygga en ny image, och du kan verifiera vilken revision som faktiskt körs. [`docs/Labb5.md`](../docs/Labb5.md)**

### Steg 6

**Give the Beacon web app a system-assigned managed identity and let it read a secret from Azure Key Vault without storing a password in code, Git, GitHub, app settings or terminal history. [`docs/Labb6.md`](../docs/Labb6.md)**
