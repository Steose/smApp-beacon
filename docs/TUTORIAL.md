# Handledning

## Vad appen är

**Beacon är en enkel .NET 10-webbapp som visar appens status och har en hälsokontroll. Den körs i Azure och använder automatiserad driftsättning, skalning, containrar och säker hantering av hemligheter.**

## Så kör du den lokalt

### Steg 1

**I det här steget skapar du en minimal webbapp i .NET 10 med slutpunkter för status och hälsokontroll. När du är klar finns appen och två integrationstester i ett lokalt Git-arkiv. [`docs/Labb1.md`](../docs/Labb1.md)**

### Steg 2

**I det här steget publicerar du Beacon till Azure App Service, skalar appen från en till tre instanser och aktiverar plattformens hälsokontroll. När du är klar har du verifierat både appens svar och dess skalningskonfiguration innan resurserna tas bort. [`docs/Labb2.md`](../docs/Labb2.md)**

### Steg 3

**I det här steget återskapar du Beacon i Azure, gör en manuell driftsättning och förbereder GitHub för framtida driftsättningar via GitHub Actions. När du är klar finns en fungerande webbapp och en skyddad publiceringsprofil i GitHub Secrets. [`docs/Labb3.md`](../docs/Labb3.md)**

### Steg 4

**I det här steget beskriver du Beacons App Service-plan och webbapp som infrastruktur som kod med Bicep. Du validerar och driftsätter mallen, verifierar att den är idempotent och kopplar driftsättningen till ditt arbetsflöde, antingen automatiskt eller via ett dokumenterat lokalt skript. [`docs/Labb4.md`](../docs/Labb4.md)**

### Steg 5

**I det här steget paketerar du Beacon som en container, lagrar avbildningen i ett eget Azure Container Registry (ACR) och kör den i Azure Container Apps. Efter labben kan en push bygga en ny avbildning, och du kan verifiera vilken revision som faktiskt körs. [`docs/Labb5.md`](../docs/Labb5.md)**

### Steg 6

**I det här steget ger du Beacon-webbappen en systemtilldelad hanterad identitet och låter den läsa en hemlighet från Azure Key Vault utan att lagra ett lösenord i koden, Git, GitHub, appinställningar eller terminalhistoriken. [`docs/Labb6.md`](../docs/Labb6.md)**

## Driftsättningsstrategi

- **App Service uppdateras på plats.** Arbetsflödet `deploy.yml` publicerar det byggda paketet direkt till den befintliga webbappen med `azure/webapps-deploy`. Det använder ingen driftsättningsplats och gör därför inget blågrönt byte. Strategin är enkel för labben och följs av en kontroll av `/health`, men den ger inte samma säkra trafikväxling och snabba återställning som en platsbaserad driftsättning.
- **Container Apps får en ny revision som rullas ut manuellt.** Arbetsflödet `deploy-container.yml` testar appen, bygger avbildningen och pushar både en unik tagg med commitens SHA och `latest` till ACR. Pipelinen ändrar däremot inte Container App. SHA-taggen skrivs ut och används vid en separat manuell utrullning med `az containerapp update`. När avbildningsreferensen ändras skapar Container Apps en ny revision. Det gör den driftsatta versionen entydig och ger kontroll över när utrullningen sker, samtidigt som tidigare revisioner kan granskas eller användas vid återställning.

### 1. Var mina hemligheter finns och vad de används till

- Jag valde att lagra applikationens hemlighet i Azure Key Vault. Webbappen får bara en Key Vault-referens i inställningen `MY_SECRET`, inte själva värdet.
- Jag valde bort att lagra hemligheten i källkod, Bicep-parametrar, terminalhistorik eller vanliga App Service-inställningar. Då kan värdet bytas utan kodändring och risken för att det hamnar i Git minskar.
- `AZURE_CREDENTIALS` finns fortfarande som en GitHub-hemlighet för den del av pipelinen där OIDC-migreringen inte är färdig. Containerflödet använder dessutom ACR:s administratörslösenord genom `ACR_PASSWORD`. Dessa är kvarvarande kompromisser, inte målbilden.

### 2. Hur hemligheterna hanteras

- Jag valde `read -rs` när värdet matades in, så det varken visades i terminalen eller sparades i historiken.
- Jag valde `readEnvironmentVariable('SECRET_VALUE')` i parameterfilen och `@secure()` i Bicep. Därmed kan infrastrukturen versionshanteras utan att hemligheten följer med.
- Jag valde en Key Vault-referens i `MY_SECRET`. Appen kan läsa den som en vanlig miljövariabel och behöver ingen egen klient för Key Vault.
- Jag valde bort att skicka hemligheten som ett argument till Azure CLI, eftersom kommandoraden då kan sparas i shellhistoriken och synas i loggar.

### 3. Behörighetsmodell och minsta privilegium

- **Varför valde jag åtkomstprinciper i stället för RBAC?**

  Jag valde Key Vaults åtkomstprinciper eftersom mitt Contributor-konto kan konfigurera dem. Jag valde bort Azure RBAC i den här labben eftersom rolltilldelningar kräver en behörighet som jag inte kan förutsätta. RBAC är fortfarande mitt förstahandsval i en produktionsmiljö där rätt behörighet finns.

- **Vilka behörigheter får webbappens identitet, och varför?**

  Webbappens systemtilldelade identitet får bara `get` och `list`, eftersom appen enbart ska läsa hemligheten. Jag valde bort `set` och andra skrivbehörigheter för appen.

- **Vilka behörigheter får den identitet som driftsätter, och varför?**

  Min driftsättningsidentitet får `get`, `list` och `set`, eftersom jag behöver skapa, kontrollera och rotera värdet. Den får inte fler Key Vault-behörigheter än uppgiften kräver.

- **Varför begränsas Contributor eller AcrPull till en resursgrupp eller ett register i stället för hela prenumerationen?**

  Jag valde den minsta användbara omfattningen. Contributor ska begränsas till labbens resursgrupp och `AcrPull` till det aktuella registret. Jag valde bort prenumerationsomfattning eftersom den skulle ge åtkomst till resurser som inte hör till Beacon.

### 4. Autentisering av pipelinen

- **Slutförde jag OIDC-konfigurationen eller stötte jag på ett behörighetshinder?**

  Jag valde OIDC för driftsättningssteget i App Service-flödet, med `id-token: write` och GitHub-variabler för klient-, klientorganisations- och prenumerations-ID. Jag valde en federerad identitet eftersom den ger kortlivade token och inte kräver ett sparat Azure-lösenord.

  Migreringen är däremot inte fullständig: infrastrukturjobbet använder fortfarande `AZURE_CREDENTIALS` och containerflödet använder `ACR_PASSWORD`. Jag har därför valt bort att radera dessa hemligheter nu. De ska tas bort först när båda arbetsflödena har klarat en fullständig rivning och återuppbyggnad med OIDC eller hanterad identitet.

### 5. Kvarvarande begränsningar och nästa steg

- **Vilka begränsningar finns kvar, och vad skulle jag förbättra härnäst?**

  `MY_SECRET` kopplas till webbappen med Azure CLI och återskapas därför inte automatiskt när App Service byggs om. `security.bicep` ingår inte heller i `provision-all.sh`. Mitt nästa val skulle vara att låta en Bicep-mall äga hela samlingen av appinställningar och lägga säkerhetsdriftsättningen i provisioneringsflödet.

  Jag valde tills vidare ACR:s administratörsuppgifter eftersom det fungerade med mina nuvarande behörigheter. Jag valde bort hanterad identitet med `AcrPull` i den färdiga lösningen eftersom rolltilldelningen inte är automatiserad. Nästa förbättring är att ersätta registerlösenordet med en systemtilldelad identitet och en registerbegränsad `AcrPull`-roll.

  Key Vaults mjuka borttagning behåller ett raderat valv i sju dagar. Det skyddar mot oavsiktlig radering, men innebär också att samma globala namn inte omedelbart kan återanvändas.

Det här avsnittet är särskilt viktigt eftersom det visar medvetna avvägningar i stället för att framställa lösningen som perfekt.

### 6. Transportsäkerhet och infrastruktur som kod

- **Hur skyddade jag trafiken, och vad deklarerade jag som kod?**

  Jag valde HTTPS för båda körmiljöerna. App Service använder `httpsOnly` och minst TLS 1.2, medan Container Apps använder `allowInsecure: false`. Jag valde bort oskyddad HTTP-trafik.

  Jag deklarerade hanterad identitet, Key Vault och dess åtkomstprinciper i Bicep för att lösningen ska kunna granskas och återskapas. Den manuella kopplingen av `MY_SECRET` är dokumenterad som en avvikelse som senare bör flyttas till samma IaC-flöde.

## Alternativ jag övervägde

### Bicep jämfört med Azure Portal

Jag övervägde att skapa och underhålla Azure-resurserna via Azure Portal, som är användbar för att lära sig de tillgängliga inställningarna och göra snabba experiment. Jag valde Bicep för den slutliga infrastrukturen eftersom mallarna kan granskas, versionshanteras och driftsättas upprepade gånger med samma konfiguration. Jag använde endast portalen när övningen krävde en jämförelse eller en första manuell driftsättning. Därmed undviker jag odokumenterade konfigurationsändringar och kan enklare återskapa Beacon efter att resursgruppen har tagits bort.

### App Service med containrar jämfört med App Service med kod

Jag övervägde att köra en Docker-avbildning direkt i App Service, vilket skulle ge applikationen samma paketerade körmiljö lokalt och i Azure. Jag valde koddriftsättning för App Service-spåret eftersom Azure redan stöder den nödvändiga .NET 10-körmiljön och `azure/webapps-deploy` kan publicera den kompilerade applikationen utan att införa ett beroende till ett containerregister. I stället använde jag en container i det separata Container Apps-spåret. För detta lilla API skulle en container i App Service kräva byggande och lagring av avbildningar samt registerautentisering, utan en tydlig fördel jämfört med den befintliga koddriftsättningen.

### Azure Container Apps (ACA) jämfört med Azure App Service

Jag implementerade båda plattformarna för att kunna jämföra deras modeller för driftsättning och skalning. App Service är det enklare valet för Beacons primära webb-API eftersom tjänsten erbjuder direkt .NET-värdskap, hälsokontroller och ett enkelt arbetsflöde för driftsättning. Azure Container Apps passar bättre när containeravbildningen måste vara driftsättningsenheten, revisionsbaserade releaser är värdefulla eller arbetslasten behöver skalas oberoende. Jag behöll ACA som det containerbaserade alternativet, men App Service är fortfarande det enklare standardvalet för den nuvarande applikationen.

### Serverlös körning (Azure Functions) jämfört med kontinuerlig drift (App Service och Container Apps)

Jag övervägde att flytta en schemalagd kontroll av Beacons `/health`-slutpunkt till en Azure Function med en timerutlösare. En kontroll var femte minut skulle ge cirka 8 640 körningar per månad och med god marginal rymmas inom övningens kostnadsfria kvot. Lösningen skulle samtidigt kräva separat Function-infrastruktur, lagring, driftsättning och dokumentation. Jag valde de befintliga lösningarna med App Service och Container Apps eftersom Beacon är en HTTP-applikation som ska svara konsekvent och redan har plattformsbaserade hälsokontroller. Jag skulle ompröva Azure Functions om uppgiften blev ett fristående bakgrundsjobb, behövde händelsestyrd skalning eller kördes varje minut för att lagra historik och skicka larm.

### Åtkomstprinciper jämfört med RBAC för Azure Key Vault

Jag övervägde Azure RBAC eftersom det är den föredragna långsiktiga behörighetsmodellen och kan tilldela snävt avgränsade roller, exempelvis Key Vault Secrets User. Jag valde Key Vaults åtkomstprinciper för den här labben eftersom de kan konfigureras med min befintliga Contributor-behörighet, medan RBAC-rolltilldelningar kräver ytterligare behörighet. Webbappens identitet får endast `get` och `list`, medan identiteten som driftsätter får `get`, `list` och `set`. Jag skulle ersätta åtkomstprinciperna med RBAC i en miljö där den nödvändiga behörigheten för rolltilldelningar och automatiserad driftsättning av roller finns.
