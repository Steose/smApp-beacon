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

echo "Enabling publishing credentials for Azure App Service"
az resource update \
  --resource-group rg-clo25-steven \
  --namespace Microsoft.Web \
  --resource-type basicPublishingCredentialsPolicies \
  --name scm \
  --parent sites/app-clo25-steven \
  --set properties.allow=true
echo "Retrieving publishing profile for Azure App Service"
az webapp deployment list-publishing-profiles \
  --name app-clo25-steven \
  --resource-group rg-clo25-steven \
  --xml > publish-profile.xml
echo "Setting publishing profile as GitHub secret"
gh secret set AZURE_WEBAPP_PUBLISH_PROFILE < publish-profile.xml
rm publish-profile.xml