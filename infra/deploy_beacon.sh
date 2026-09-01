#!/usr/bin/env sh
set -eu

echo "Creating resource group for Azure App Service"
az group create \
  --name rg-clo25-steven \
  --location swedencentral

echo "Creating app service plan for Azure App Service"
az appservice plan create \
  --name asp-clo25-steven \
  --resource-group rg-clo25-steven \
  --location swedencentral \
  --sku B1 \
  --is-linux \
  --async-scaling-enabled true

echo "Creating web app for Azure App Service"
az webapp create \
  --name app-clo25-steven \
  --resource-group rg-clo25-steven \
  --plan asp-clo25-steven \
  --runtime "DOTNETCORE|10.0"

echo "Deploying web app to Azure App Service"
az webapp deploy \
  --resource-group rg-clo25-steven \
  --name app-clo25-steven \
  --src-path artifacts/app.zip \
  --type zip
