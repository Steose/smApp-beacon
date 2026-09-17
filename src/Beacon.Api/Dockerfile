# Stage 1: Build the app with the .NET SDK
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
ARG PROJECT=src/Beacon.Api/Beacon.Api.csproj
WORKDIR /src
COPY . .
RUN dotnet restore ./$PROJECT
RUN dotnet publish ./$PROJECT \
    --configuration Release \
    --output /app/publish

# Stage 2: Run the app with the runtime only. No SDK, No source.
FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS final
WORKDIR /app
COPY --from=build /app/publish .
ENTRYPOINT ["dotnet", "Beacon.Api.dll"]
