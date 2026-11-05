# Beacon

En liten webbapp som byggs vidare på under kursen Skalbara molnapplikationer.

Full dokumentation: [`docs/TUTORIAL.md`](./docs/TUTORIAL.md)

## How to run Beacon - Networking and Helm

1. Create the pull secret, with a GitHub token that has only `read:packages`. The first line waits for you to
   paste the token:

   ```bash
   printf 'GitHub token: ' && read -rs GHCR_TOKEN && echo

   kubectl create secret docker-registry ghcr-secret \
     --docker-server=ghcr.io \
     --docker-username=github-username \
     --docker-password=$GHCR_TOKEN
   ```

2. Create the app's secret:

   ```bash
   kubectl create secret generic beacon-secret \
     --from-literal=BEACON_API_KEY='your-key'
   ```

3. Install the chart:

   ```bash
   helm upgrade --install beacon ./charts/beacon
   ```

## AKS and Pipeline

A green run of the pipeline: [Release version 5](https://github.com/Steose/smApp-beacon/actions/runs/41999808984)