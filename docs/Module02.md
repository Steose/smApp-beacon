# Configuration

## What you will build

**In this tutorial, you configure Beacon so Kubernetes can update it safely, check its health, provide settings outside the image, and pull a private image built by GitHub Actions. When you are finished, Beacon can roll forward and back without losing service, and no real secret is stored in Git.**

You will:

1. prepare the cluster and an in-cluster test client
2. deploy a new Beacon version and roll it back
3. add readiness and liveness probes
4. provide settings with a ConfigMap and a Secret
5. build and push versioned images to GitHub Container Registry
6. configure Kubernetes to pull the private image

The completed files are:

```text
.github/workflows/build-and-push-image.yml
docs/secret.example.yaml
k8s/configmap.yaml
k8s/deployment.yaml
k8s/service.yaml
src/Beacon.Api/Program.cs
```

This guide is adapted for the Beacon repository from [Module 02: Configuration](https://codex-kubernetes.pages.dev/modules/02/).

## Before you start

Complete Module 01 first. You need Docker, `kubectl`, `k3d`, Git, and the GitHub CLI (`gh`). Run all commands from the repository root.

### Step 1: Start and verify the cluster

Check the cluster:

```bash
k3d cluster list
```

If `clo25` shows `0/1` under `SERVERS`, start it:

```bash
k3d cluster start clo25
```

Wait about 30 seconds, then verify the context and node:

```bash
kubectl config current-context
kubectl get nodes
```

The current context should be `k3d-clo25`, and the node should become `Ready`.

### Step 2: Restore the Module 01 resources

Apply the Kubernetes files:

```bash
kubectl apply -f k8s/
kubectl get pods
```

If the Beacon pods report `ImagePullBackOff` because `beacon:v1` is no longer available in the cluster, rebuild and import it:

```bash
docker build \
  --file src/Beacon.Api/Dockerfile \
  --tag beacon:v1 \
  .

k3d image import beacon:v1 --cluster clo25
kubectl rollout restart deployment beacon
kubectl rollout status deployment beacon
```

### Step 3: Create a toolbox Pod

Create a small Pod that can call Beacon from inside the cluster:

```bash
kubectl run toolbox \
  --image=curlimages/curl:8.22.0 \
  --command -- sleep infinity

kubectl wait --for=condition=Ready pod/toolbox --timeout=90s
```

Test the Service:

```bash
kubectl exec toolbox -- curl -s http://beacon/
```

Expected shape:

```json
{
  "app": "Beacon",
  "status": "ok",
  "version": "1"
}
```

The toolbox is an unmanaged Pod. If the cluster is stopped and started, recreate it when necessary.

## Lab 1: Roll out a new version and roll back

### Step 1: Change the application version

Open `src/Beacon.Api/Program.cs` and change the version returned by `/`:

```csharp
app.MapGet("/", () => new
{
    app = "Beacon",
    status = "ok",
    version = "2"
});
```

### Step 2: Build and import version 2

```bash
docker build \
  --file src/Beacon.Api/Dockerfile \
  --tag beacon:v2 \
  .

k3d image import beacon:v2 --cluster clo25
```

### Step 3: Update the Deployment image

Set the running container to version 2:

```bash
kubectl set image deployment/beacon beacon=beacon:v2
kubectl rollout status deployment beacon
```

Inspect the rollout:

```bash
kubectl get pods
kubectl rollout history deployment beacon
```

Call the Service several times while the rollout proceeds:

```bash
for request in 1 2 3 4 5; do
  kubectl exec toolbox -- curl -s http://beacon/
  sleep 1
done
```

Kubernetes performs a rolling update: it creates new Pods and removes old Pods only as replacements become available.

### Step 4: Roll back

Return to the previous Deployment revision:

```bash
kubectl rollout undo deployment beacon
kubectl rollout status deployment beacon
kubectl exec toolbox -- curl -s http://beacon/
```

The response should show version 1 again.

`kubectl rollout undo` changes the live cluster only. Keep `k8s/deployment.yaml` consistent with the version you want, or the next `kubectl apply` can overwrite the rollback.

### Step 5: Return to version 2

Update the image in `k8s/deployment.yaml`:

```yaml
containers:
  - name: beacon
    image: beacon:v2
```

Apply and verify it:

```bash
kubectl apply -f k8s/deployment.yaml
kubectl rollout status deployment beacon
kubectl exec toolbox -- curl -s http://beacon/
```

## Lab 2: Add health probes

Beacon already exposes `/health`. Kubernetes can use it for two different decisions:

| Probe | Question | Failure result |
|---|---|---|
| Readiness | Can this Pod receive traffic now? | Removes the Pod from Service endpoints |
| Liveness | Is this container still healthy? | Restarts the container |

### Step 1: Add readiness and liveness probes

Add these fields to the Beacon container in `k8s/deployment.yaml`:

```yaml
readinessProbe:
  httpGet:
    path: /health
    port: 8080
  periodSeconds: 5
livenessProbe:
  httpGet:
    path: /health
    port: 8080
  initialDelaySeconds: 15
  periodSeconds: 10
```

Apply the change:

```bash
kubectl apply -f k8s/deployment.yaml
kubectl rollout status deployment beacon
kubectl get pods
```

All Beacon Pods should show `1/1` in the `READY` column.

### Step 2: Test a broken readiness probe

Temporarily change only the readiness path to a missing endpoint:

```yaml
readinessProbe:
  httpGet:
    path: /healthz
    port: 8080
```

Apply it and observe the rollout:

```bash
kubectl apply -f k8s/deployment.yaml
kubectl get pods --watch
```

The new Pods remain `0/1`, while old ready Pods keep serving traffic. Stop the watch with `Ctrl+C`, then inspect the failure:

```bash
kubectl describe pods -l app=beacon
kubectl exec toolbox -- curl -s http://beacon/
```

Look for readiness-probe failures with HTTP status `404`. The Service should still answer through the old ready Pods.

Restore the path to `/health`, then apply it:

```bash
kubectl apply -f k8s/deployment.yaml
kubectl rollout status deployment beacon
```

### Step 3: Understand liveness failures safely

A broken liveness path causes Kubernetes to restart containers after repeated failures. Do not leave all replicas with a broken liveness probe. If you test this behavior, immediately restore `/health`, apply the file, and verify recovery:

```bash
kubectl get pods
kubectl get pods -o custom-columns=NAME:.metadata.name,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount
```

Readiness protects traffic during startup or temporary unavailability. Liveness should detect a process that cannot recover without a restart.

## Lab 3: Move configuration outside the image

The same container image should work in multiple environments. Put ordinary settings in a ConfigMap and sensitive values in a Secret.

### Step 1: Read environment variables in Beacon

Add an `/info` endpoint to `src/Beacon.Api/Program.cs`:

```csharp
app.MapGet("/info", () => new
{
    app = "Beacon",
    machine = Environment.MachineName,
    environment = Environment.GetEnvironmentVariable("BEACON_ENVIRONMENT") ?? "unset",
    message = Environment.GetEnvironmentVariable("BEACON_MESSAGE") ?? "unset",
    apiKeySet = !string.IsNullOrEmpty(
        Environment.GetEnvironmentVariable("BEACON_API_KEY"))
});
```

Build and import a new local image for this code change:

```bash
docker build \
  --file src/Beacon.Api/Dockerfile \
  --tag beacon:v3 \
  .

k3d image import beacon:v3 --cluster clo25
```

Change the Deployment image to `beacon:v3` before applying later steps.

### Step 2: Create the ConfigMap manifest

Create `k8s/configmap.yaml`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: beacon-config
data:
  BEACON_ENVIRONMENT: development
  BEACON_MESSAGE: Hello from Kubernetes
```

Apply and inspect it:

```bash
kubectl apply -f k8s/configmap.yaml
kubectl get configmap beacon-config
kubectl describe configmap beacon-config
```

### Step 3: Create the Secret without exposing its value

Read the value silently and create the Secret directly in the cluster:

```bash
read -rs "BEACON_API_KEY?Enter the Beacon API key: "
echo

kubectl create secret generic beacon-secret \
  --from-literal=BEACON_API_KEY="$BEACON_API_KEY" \
  --dry-run=client \
  --output=yaml | kubectl apply -f -

unset BEACON_API_KEY
```

Confirm that the Secret exists without printing its contents:

```bash
kubectl get secret beacon-secret
```

Do not commit a real Secret manifest. A documentation-only example may contain a placeholder:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: beacon-secret
type: Opaque
stringData:
  BEACON_API_KEY: replace-at-deployment-time
```

Kubernetes Secret data is base64-encoded, not automatically encrypted from every cluster user. Access must still be restricted.

### Step 4: Inject both resources into the Pods

Add `envFrom` to the Beacon container in `k8s/deployment.yaml`:

```yaml
envFrom:
  - configMapRef:
      name: beacon-config
  - secretRef:
      name: beacon-secret
```

Apply all configuration and wait:

```bash
kubectl apply -f k8s/configmap.yaml
kubectl apply -f k8s/deployment.yaml
kubectl rollout status deployment beacon
```

Call `/info`:

```bash
kubectl exec toolbox -- curl -s http://beacon/info
```

Expected shape:

```json
{
  "app": "Beacon",
  "machine": "beacon-...",
  "environment": "development",
  "message": "Hello from Kubernetes",
  "apiKeySet": true
}
```

The endpoint reports only whether the key exists; it never returns the value.

### Step 5: Update the ConfigMap

Change `BEACON_MESSAGE` in `k8s/configmap.yaml`, then run:

```bash
kubectl apply -f k8s/configmap.yaml
kubectl exec toolbox -- curl -s http://beacon/info
```

The existing Pods still show the old value because environment variables are read when a container starts. Restart the Deployment:

```bash
kubectl rollout restart deployment beacon
kubectl rollout status deployment beacon
kubectl exec toolbox -- curl -s http://beacon/info
```

The new Pods now report the changed message.

## Lab 4: Build and use an image from GHCR

A local k3d image import is useful for development. A shared or remote cluster needs a registry. This repository uses GitHub Container Registry (`ghcr.io`) and a commit-based image tag.

### Step 1: Review the build workflow

The file `.github/workflows/build-and-push-image.yml` should contain this essential structure:

```yaml
name: Build and Push Image

on:
  workflow_dispatch:
  push:
    branches:
      - main
    paths-ignore:
      - "**.md"
      - "docs/**"

permissions:
  contents: read
  packages: write

jobs:
  build-and-push:
    runs-on: ubuntu-24.04
    steps:
      - name: Check Out the Code
        uses: actions/checkout@v7

      - name: Sign In to the Registry
        uses: docker/login-action@v4
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Set Up QEMU
        uses: docker/setup-qemu-action@v4

      - name: Set Up Buildx
        uses: docker/setup-buildx-action@v4

      - name: Build and Push the Image
        run: |
          owner=$(echo "${{ github.repository_owner }}" | tr 'A-Z' 'a-z')
          image="ghcr.io/$owner/beacon:${GITHUB_SHA::7}"
          docker buildx build \
            --file src/Beacon.Api/Dockerfile \
            --platform linux/amd64,linux/arm64 \
            --tag "$image" \
            --push \
            .
```

The tag is the first seven characters of the commit SHA. It is immutable evidence of exactly which source revision produced the image.

### Step 2: Push the workflow and watch it

Commit the relevant code and workflow changes, then push them to `main`:

```bash
git add .github/workflows/build-and-push-image.yml \
  src/Beacon.Api/Program.cs \
  k8s
git commit -m "Configure Beacon for Kubernetes"
git push
```

Watch the newest run:

```bash
gh run list --workflow build-and-push-image.yml --limit 1

RUN_ID=$(gh run list \
  --workflow build-and-push-image.yml \
  --limit 1 \
  --json databaseId \
  --jq '.[0].databaseId')

gh run watch "$RUN_ID"
```

Wait for the workflow to finish successfully.

### Step 3: Create a GHCR pull Secret

The package produced by this exercise is private unless you explicitly change its visibility. Create a classic personal access token with the minimum `read:packages` permission. Enter it silently and create the registry Secret:

```bash
read -rs "GHCR_TOKEN?Enter the GHCR read token: "
echo

kubectl create secret docker-registry ghcr-secret \
  --docker-server=ghcr.io \
  --docker-username=YOUR_GITHUB_USERNAME \
  --docker-password="$GHCR_TOKEN" \
  --dry-run=client \
  --output=yaml | kubectl apply -f -

unset GHCR_TOKEN
```

Replace `YOUR_GITHUB_USERNAME` with your username. Do not store the token in the repository or a shell command committed to a script.

### Step 4: Configure the Deployment to use GHCR

Get the image tag:

```bash
git rev-parse --short=7 HEAD
```

Update `k8s/deployment.yaml` with your lowercase GitHub owner and returned tag:

```yaml
spec:
  template:
    spec:
      imagePullSecrets:
        - name: ghcr-secret
      containers:
        - name: beacon
          image: ghcr.io/your-github-username/beacon:abcdef0
```

Apply and verify the rollout:

```bash
kubectl apply -f k8s/deployment.yaml
kubectl rollout status deployment beacon
kubectl get pods
kubectl exec toolbox -- curl -s http://beacon/
```

If a Pod reports `ImagePullBackOff`, inspect it:

```bash
kubectl describe pod POD_NAME
```

Common causes are an incorrect owner, an image tag that was not pushed, a missing `ghcr-secret`, or a token without `read:packages` access.

### Step 5: Prove that a new image needs a new tag

Push another code change so the workflow publishes a new commit tag. Applying an unchanged Deployment does not deploy that image:

```bash
kubectl apply -f k8s/deployment.yaml
```

Kubernetes reports the Deployment as `unchanged` because its declared image reference did not change. Update the tag in `k8s/deployment.yaml`, then apply it:

```bash
kubectl apply -f k8s/deployment.yaml
kubectl rollout status deployment beacon
```

Commit the new image reference so Git remains the source of truth:

```bash
git add k8s/deployment.yaml
git commit -m "Roll out the new Beacon image"
git push
```

## Verify the completed configuration

Run these checks:

```bash
kubectl get deployment beacon
kubectl get pods -l app=beacon
kubectl get service beacon
kubectl get configmap beacon-config
kubectl get secret beacon-secret ghcr-secret
kubectl exec toolbox -- curl -s http://beacon/
kubectl exec toolbox -- curl -s http://beacon/health
kubectl exec toolbox -- curl -s http://beacon/info
```

Confirm that:

- all three Beacon replicas are ready
- `/`, `/health`, and `/info` answer successfully
- `/info` reports the ConfigMap values and `apiKeySet: true`
- `k8s/deployment.yaml` contains both health probes
- the image uses `ghcr.io/<owner>/beacon:<commit-tag>`, not `latest`
- no real API key, registry token, or rendered Secret is tracked by Git

Check tracked files for likely secret material before committing:

```bash
git grep -n -E 'BEACON_API_KEY:|GHCR_TOKEN|docker-password' -- ':!k8s/docs/Module02.md'
```

Review every match. Placeholder documentation is acceptable; a real credential is not.

## When you are done

Stop the cluster to release local resources:

```bash
k3d cluster stop clo25
```

The Deployment, Service, ConfigMap, and Secrets remain in the stopped cluster. The standalone toolbox Pod may need to be recreated after the next start.

## Summary

- **Rolling updates replace Pods gradually.** Ready old Pods continue serving until their replacements are ready, which avoids downtime during a healthy deployment.
- **Rollback is fast but must be reflected in Git.** `kubectl rollout undo` changes the cluster, while the manifest remains the durable desired state.
- **Readiness controls traffic; liveness controls restarts.** A failed readiness probe removes a Pod from Service endpoints. A failed liveness probe restarts its container.
- **ConfigMaps and Secrets separate configuration from the image.** This lets one immutable image run in different environments. Environment-variable changes require new Pods, so restart the rollout after changing the ConfigMap or Secret.
- **A Secret is not source-code storage.** Create real values at deployment time, restrict access, and commit only safe examples.
- **A registry makes images available outside one local runtime.** GitHub Actions builds and pushes Beacon to GHCR, and `imagePullSecrets` lets Kubernetes authenticate to a private package.
- **Every release needs an explicit image tag.** A commit-based tag identifies the exact build and gives Kubernetes a changed desired state to roll out.
