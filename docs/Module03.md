# Networking and Helm

## What you will build

**In this tutorial, you make Beacon reachable through a Kubernetes Ingress and package its Kubernetes resources as a Helm chart. When you are finished, DNS and a Service connect applications inside the cluster, Traefik routes traffic from outside, and one Helm command installs the complete solution.**

You will:

1. verify the cluster, toolbox, and Helm installation
2. use Kubernetes DNS to reach a Service
3. compare `ClusterIP` and `LoadBalancer` Services
4. expose Beacon through the Traefik ingress controller
5. observe traffic being balanced across Beacon Pods
6. package the Deployment, Service, ConfigMap, and Ingress as a Helm chart
7. parameterize replicas, the image tag, host name, and resource names
8. remove and recreate the complete release with Helm

The completed files are:

```text
charts/
└── beacon/
    ├── Chart.yaml
    ├── values.yaml
    └── templates/
        ├── configmap.yaml
        ├── deployment.yaml
        ├── ingress.yaml
        └── service.yaml
k8s/
└── ingress.yaml
README.md
```

This guide is adapted for the Beacon repository from [Module 03: Networking and Helm](https://codex-kubernetes.pages.dev/modules/03/).

## Before you start

Complete Module 02 first. The `clo25` cluster should contain Beacon, its two Secrets, and an image from GHCR. Run all commands from the repository root.

### Step 1: Start the cluster

Check the cluster:

```bash
k3d cluster list
```

If `clo25` shows `0/1` under `SERVERS`, start it:

```bash
k3d cluster start clo25
```

Wait about 30 seconds, then verify the node:

```bash
kubectl get nodes
```

The node should report `Ready`.

### Step 2: Verify or recreate the toolbox

Check whether the toolbox Pod from Module 02 exists:

```bash
kubectl get pod toolbox
```

If Kubernetes reports `NotFound`, recreate it:

```bash
kubectl run toolbox \
  --image=curlimages/curl:8.22.0 \
  --command -- sleep infinity

kubectl wait --for=condition=Ready pod/toolbox --timeout=90s
```

Call Beacon through its Service:

```bash
kubectl exec toolbox -- curl -s http://beacon/info
```

Expected shape:

```json
{
  "app": "Beacon",
  "machine": "beacon-...",
  "environment": "local",
  "message": "Hello again",
  "apiKeySet": true
}
```

### Step 3: Verify Helm

Check the installed Helm version:

```bash
helm version --short
```

This course uses Helm 4. The output should begin with `v4`.

## Lab 1: Discover Services with Kubernetes DNS

Kubernetes runs an internal DNS service. Each Service receives a DNS name, so applications use stable names instead of changing Pod IP addresses.

### Step 1: Use the Service name

The short name works for clients in the same namespace:

```bash
kubectl exec toolbox -- curl -s http://beacon/info
```

The request follows this route:

```text
toolbox -> cluster DNS -> beacon Service -> one ready Beacon Pod
```

The Service remains stable even when Deployment Pods are replaced.

### Step 2: Use the namespace-qualified name

Call the Service using its name and namespace:

```bash
kubectl exec toolbox -- curl -s http://beacon.default/info
```

Call it using the fully qualified cluster name:

```bash
kubectl exec toolbox -- \
  curl -s http://beacon.default.svc.cluster.local/info
```

All three names identify the same Service:

| Name | Where it works |
|---|---|
| `beacon` | The same namespace |
| `beacon.default` | Any namespace in the cluster |
| `beacon.default.svc.cluster.local` | Any namespace, using the full cluster domain |

### Step 3: Try the wrong namespace

Ask for Beacon in `kube-system`:

```bash
kubectl exec toolbox -- curl -s http://beacon.kube-system/info
```

Expected result:

```text
command terminated with exit code 6
```

Exit code 6 means `curl` could not resolve the name. No Service named `beacon` exists in the `kube-system` namespace.

### Step 4: Inspect Service types

List Services in the default namespace:

```bash
kubectl get services
```

Beacon has the default type, `ClusterIP`. It is reachable only inside the cluster and has no external IP address.

Now list the system Services:

```bash
kubectl get services --namespace kube-system
```

Look for:

- `kube-dns`, a `ClusterIP` Service that resolves cluster names
- `metrics-server`, which collects CPU and memory metrics
- `traefik`, a `LoadBalancer` Service that accepts traffic entering the cluster

In this local k3d cluster, Traefik's external address belongs to Docker networking. It is not a public internet address.

## Lab 2: Route external traffic through an Ingress

An Ingress and an ingress controller have different responsibilities:

| Component | Responsibility |
|---|---|
| Ingress | Declares that a path or host should route to a Service |
| Ingress controller | Reads Ingress resources and handles the traffic |

The k3d cluster includes Traefik as its ingress controller.

### Step 1: Find Traefik

List the system Pods:

```bash
kubectl get pods --namespace kube-system
```

You should see Pods whose names begin with `traefik-` and `svclb-traefik-`:

- `traefik-...` runs the ingress controller.
- `svclb-traefik-...` connects the local LoadBalancer Service to the cluster ports.

List the available ingress classes:

```bash
kubectl get ingressclass
```

Expected shape:

```text
NAME                CONTROLLER
traefik (default)   traefik.io/ingress-controller
```

An ingress class selects which controller should process an Ingress.

### Step 2: Confirm there is no Beacon route yet

Module 01 mapped local port `8080` to port `80` on the k3d load balancer. Call it before adding an Ingress:

```bash
curl -s -i http://localhost:8080/info
```

Traefik answers with `HTTP/1.1 404 Not Found` because it has no rule for Beacon yet.

### Step 3: Create an Ingress with an incorrect class

Create `k8s/ingress.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: beacon
spec:
  ingressClassName: nginx
  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: beacon
                port:
                  number: 80
```

The class is deliberately incorrect. Apply and inspect it:

```bash
kubectl apply -f k8s/ingress.yaml
kubectl get ingress
```

The Ingress exists, but its `ADDRESS` remains empty because no `nginx` ingress controller is installed.

Call Beacon again:

```bash
curl -s -i http://localhost:8080/info
```

The response remains `404 Not Found`. An Ingress is only a rule; it does nothing without a matching controller.

### Step 4: Select the Traefik class

Change the class in `k8s/ingress.yaml`:

```yaml
spec:
  ingressClassName: traefik
```

Apply and inspect it:

```bash
kubectl apply -f k8s/ingress.yaml
kubectl get ingress
```

The `CLASS` should be `traefik`, and `ADDRESS` should now contain the controller address.

Call Beacon without port forwarding:

```bash
curl -s http://localhost:8080/info
```

Traefik matches the `/` prefix, forwards the request to the `beacon` Service on port 80, and the Service sends it to a ready Pod on port 8080.

### Step 5: Observe load balancing

Call the endpoint several times:

```bash
for request in 1 2 3 4 5 6; do
  curl -s http://localhost:8080/info
done
```

Compare the `machine` values. Requests should be answered by more than one Beacon Pod. The Service spreads traffic across ready endpoints.

### Step 6: Commit the Ingress

```bash
git add k8s/ingress.yaml
git commit -m "Add an Ingress"
git push
```

## Lab 3: Package Beacon as a Helm chart

Plain manifests work, but every environment-specific change requires editing YAML and applying several files. A Helm chart packages those files and puts changing values in one place.

| Bicep concept | Helm equivalent |
|---|---|
| Template | Files in `charts/beacon/templates/` |
| Parameter file | `charts/beacon/values.yaml` |
| Parameter reference | `{{ .Values.name }}` |
| Deployment command | `helm upgrade --install` |

Helm requires the exact names `Chart.yaml` and `values.yaml`. Do not rename them to `.yml`.

### Step 1: Create the chart metadata

Create the directory structure:

```bash
mkdir -p charts/beacon/templates
```

Create `charts/beacon/Chart.yaml`:

```yaml
apiVersion: v2
name: beacon
description: Beacon, a small web API, on Kubernetes
type: application
version: 0.1.0
appVersion: "4"
```

`version` identifies the chart version. `appVersion` is descriptive metadata for the application version.

### Step 2: Copy the manifests into the chart

Copy the four application manifests:

```bash
cp \
  k8s/configmap.yaml \
  k8s/deployment.yaml \
  k8s/ingress.yaml \
  k8s/service.yaml \
  charts/beacon/templates/
```

Render the chart without changing the cluster:

```bash
helm template beacon ./charts/beacon
```

At this point, the rendered resources should match the original manifests.

### Step 3: Let Helm take ownership

Try to install the release:

```bash
helm upgrade --install beacon ./charts/beacon
```

Helm refuses because the existing resources were created by `kubectl` and do not contain Helm ownership metadata.

Delete only the resources represented by the plain manifests:

```bash
kubectl delete -f k8s/
```

The `beacon-secret` and `ghcr-secret` Secrets remain because they are intentionally not stored in those files.

Install again:

```bash
helm upgrade --install beacon ./charts/beacon
kubectl rollout status deployment beacon
curl -s http://localhost:8080/info
```

From this point, Helm owns the four chart resources. Upgrade them with Helm rather than `kubectl apply -f k8s/`.

### Step 4: Parameterize the replica count

Create `charts/beacon/values.yaml`:

```yaml
replicaCount: 3
```

Replace the fixed replica count in `charts/beacon/templates/deployment.yaml`:

```yaml
spec:
  replicas: {{ .Values.replicaCount }}
```

Verify the rendered value:

```bash
helm template beacon ./charts/beacon | grep replicas
```

Expected output:

```text
  replicas: 3
```

Change `replicaCount` to `5`, upgrade, and inspect the Pods:

```bash
helm upgrade --install beacon ./charts/beacon
kubectl get pods
```

Five Beacon Pods should run. Return the value to `3` and upgrade again:

```bash
helm upgrade --install beacon ./charts/beacon
kubectl get pods
```

Helm records a new release revision for every successful upgrade.

### Step 5: Parameterize the image tag

Find the successful image tag from Module 02:

```bash
gh run list \
  --workflow build-and-push-image.yml \
  --status success \
  --limit 1 \
  --json headSha \
  --jq '.[0].headSha[0:7]'
```

Add the returned tag to `charts/beacon/values.yaml`:

```yaml
replicaCount: 3
imageTag: "abcdef0"
```

Always quote the tag so YAML treats it as text.

Replace the fixed tag in the Deployment template. Use your lowercase GitHub owner:

```yaml
containers:
  - name: beacon
    image: "ghcr.io/your-github-username/beacon:{{ .Values.imageTag }}"
```

Verify the image:

```bash
helm template beacon ./charts/beacon | grep 'image:'
```

You can override a value for one command without editing the file:

```bash
helm template beacon ./charts/beacon \
  --set imageTag=try-it | grep 'image:'
```

The command-line value wins over `values.yaml`. Module 04 can use this mechanism to deploy the image tag built by a pipeline.

Upgrade using the real tag from `values.yaml`:

```bash
helm upgrade --install beacon ./charts/beacon
```

### Step 6: Parameterize the Ingress host

Add an empty host value:

```yaml
replicaCount: 3
imageTag: "abcdef0"
ingressHost: ""
```

Update `charts/beacon/templates/ingress.yaml`:

```yaml
spec:
  ingressClassName: traefik
  rules:
    - host: {{ .Values.ingressHost | quote }}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: beacon
                port:
                  number: 80
```

The `quote` function renders the value as valid YAML text. An empty host matches requests for any host, so localhost continues to work.

Upgrade and test:

```bash
helm upgrade --install beacon ./charts/beacon
curl -s http://localhost:8080/info
```

Now test host-based routing by setting:

```yaml
ingressHost: "beacon.127.0.0.1.nip.io"
```

Upgrade and call the named host:

```bash
helm upgrade --install beacon ./charts/beacon
kubectl get ingress
curl -s http://beacon.127.0.0.1.nip.io:8080/info
```

Calling `localhost:8080` now returns 404 because the Ingress accepts only the configured host.

If your network blocks `nip.io`, skip the named-host test. Return the value to an empty string before continuing:

```yaml
ingressHost: ""
```

Apply the final value:

```bash
helm upgrade --install beacon ./charts/beacon
```

Leave the host empty for the next module because the Azure environment will have a different address.

### Step 7: Derive resource names from the release

Hard-coded resource names prevent a second release from using the same namespace. Replace application names with `{{ .Release.Name }}`.

Use this final `charts/beacon/templates/deployment.yaml` structure:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Release.Name }}
spec:
  replicas: {{ .Values.replicaCount }}
  selector:
    matchLabels:
      app: {{ .Release.Name }}
  template:
    metadata:
      labels:
        app: {{ .Release.Name }}
    spec:
      imagePullSecrets:
        - name: ghcr-secret
      containers:
        - name: {{ .Release.Name }}
          image: "ghcr.io/your-github-username/beacon:{{ .Values.imageTag }}"
          ports:
            - containerPort: 8080
          envFrom:
            - configMapRef:
                name: "{{ .Release.Name }}-config"
            - secretRef:
                name: beacon-secret
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              memory: 256Mi
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

Use this final Service template:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: {{ .Release.Name }}
spec:
  selector:
    app: {{ .Release.Name }}
  ports:
    - port: 80
      targetPort: 8080
```

Use this final ConfigMap template:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: "{{ .Release.Name }}-config"
data:
  BEACON_ENVIRONMENT: "local"
  BEACON_MESSAGE: "Hello again"
```

Use the release name for the Ingress and its backend Service:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ .Release.Name }}
spec:
  ingressClassName: traefik
  rules:
    - host: {{ .Values.ingressHost | quote }}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: {{ .Release.Name }}
                port:
                  number: 80
```

The Secrets keep their fixed names because they are created outside the chart.

Render a hypothetical release named `demo`:

```bash
helm template demo ./charts/beacon | grep -E 'name:|app:'
```

Chart-owned resources should use `demo`, while `ghcr-secret` and `beacon-secret` remain unchanged.

Upgrade the real release and verify it:

```bash
helm upgrade --install beacon ./charts/beacon
helm list
curl -s http://localhost:8080/info
```

### Step 8: Commit the chart

```bash
git add charts
git commit -m "Package the solution as a Helm chart"
git push
```

## Lab 4: Recreate the solution with one command

The chart should own the Deployment, Service, ConfigMap, and Ingress. The two Secrets remain outside Git and outside the chart.

### Step 1: Uninstall the release

```bash
helm uninstall beacon
kubectl get all
kubectl get ingress,configmap
```

The Beacon resources should be gone. The unmanaged toolbox Pod and Kubernetes API Service may remain.

Verify that the Secrets still exist:

```bash
kubectl get secrets
```

You should still see `beacon-secret` and `ghcr-secret`.

### Step 2: Install everything again

```bash
helm upgrade --install beacon ./charts/beacon
kubectl rollout status deployment beacon
curl -s http://localhost:8080/info
```

One Helm command recreates every chart-owned resource. If Traefik reports `no available server`, wait for a Pod to become ready and retry.

### Step 3: Document installation in README.md

Add an English `How to run` section that explains the required order:

1. create the GHCR pull Secret
2. create the application Secret
3. install the chart

Use commands that do not expose a real token in Git:

````markdown
## How to run Beacon

1. Create the pull secret with a GitHub token that has only `read:packages`:

   ```bash
   printf 'GitHub token: ' && read -rs GHCR_TOKEN && echo

   kubectl create secret docker-registry ghcr-secret \
     --docker-server=ghcr.io \
     --docker-username=your-github-username \
     --docker-password="$GHCR_TOKEN"

   unset GHCR_TOKEN
   ```

2. Create the application Secret:

   ```bash
   printf 'Beacon API key: ' && read -rs BEACON_API_KEY && echo

   kubectl create secret generic beacon-secret \
     --from-literal=BEACON_API_KEY="$BEACON_API_KEY"

   unset BEACON_API_KEY
   ```

3. Install the chart:

   ```bash
   helm upgrade --install beacon ./charts/beacon
   ```
````

Commit the documentation:

```bash
git add README.md
git commit -m "Document how to run Beacon"
git push
```

## Verify the completed module

Lint and render the chart:

```bash
helm lint ./charts/beacon
helm template beacon ./charts/beacon
```

Inspect the installed release and resources:

```bash
helm list
helm status beacon
kubectl get deployment,service,ingress,configmap
kubectl get pods -l app=beacon
```

Test both routes:

```bash
kubectl exec toolbox -- curl -s http://beacon/info
curl -s http://localhost:8080/info
```

Confirm that:

- the three Beacon Pods are ready
- internal DNS resolves the `beacon` Service
- Traefik accepts the Ingress and routes port 8080 traffic
- the Service balances requests across ready Pods
- `values.yaml` contains the replica count, image tag, and Ingress host
- chart-owned names are derived from `.Release.Name`
- the chart passes `helm lint`
- the two real Secrets are not stored in the chart or tracked by Git

## When you are done

Stop the cluster to release local resources:

```bash
k3d cluster stop clo25
```

The Helm release and Secrets remain in the stopped cluster. The standalone toolbox may need to be recreated after the next start.

## Summary

- **Kubernetes DNS gives Services stable names.** Pods can use `beacon`, `beacon.default`, or the full cluster domain without knowing a Service or Pod IP address.
- **Service types control reachability.** Beacon uses `ClusterIP` for internal traffic, while Traefik's `LoadBalancer` Service provides the cluster's external entry point.
- **An Ingress is a rule, not a traffic processor.** A matching ingress controller must read the rule. In this k3d cluster, the correct class is `traefik`.
- **The Service balances traffic across ready Pods.** Repeated requests can reach different Beacon instances while clients keep using one stable address.
- **A Helm chart packages related Kubernetes resources.** `Chart.yaml` describes the package, templates describe resources, and `values.yaml` contains environment-specific settings.
- **Helm values make the chart reusable.** Replica count, image tag, and host name change without duplicating manifests, and `--set` can override a value for one deployment.
- **Release-derived names allow multiple installations.** `.Release.Name` prevents independently named releases from competing for the same application resources.
- **Helm tracks ownership and revision history.** Use `helm upgrade --install` for chart-owned resources instead of applying their plain copies with `kubectl`.
- **Secrets stay outside the chart and Git.** They must exist before installation, but uninstalling the release does not remove them.
- **One command restores the declared solution.** After the Secrets exist, `helm upgrade --install beacon ./charts/beacon` recreates the Deployment, Service, ConfigMap, and Ingress.
