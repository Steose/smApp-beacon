# Your First Cluster

## What you will build

**In this tutorial, you create a local Kubernetes cluster with k3d and run Beacon in it. When you are finished, three Beacon pods run behind one Kubernetes Service.**

You will:

1. verify the required tools
2. create and inspect a local cluster
3. build and import the Beacon container image
4. run Beacon first as a Pod and then as a Deployment
5. expose the Deployment through a Service
6. test recovery, scaling, networking, and troubleshooting

The completed Kubernetes files are already kept in this repository:

```text
k8s/
├── deployment.yaml
├── service.yaml
└── examples/
    └── pod.yaml
```

This guide is adapted for the Beacon repository from [Module 01: Your First Cluster](https://codex-kubernetes.pages.dev/modules/01/).

## Before you start

You need:

- a container runtime, such as Docker Desktop
- `kubectl`, the Kubernetes command-line client
- `k3d`, which runs a lightweight Kubernetes cluster in containers
- about 4 GB of free memory

### Step 1: Check the container runtime

Start Docker Desktop or your chosen runtime, then run:

```bash
docker ps
```

The command should print a table. An empty container list is fine. If it cannot connect to the daemon, start the runtime and try again.

### Step 2: Check kubectl

```bash
kubectl version --client
```

The output should include a client version.

### Step 3: Check k3d

```bash
k3d version
```

The output should include both a k3d version and a k3s version.

## Why Kubernetes

A container runtime can start one Beacon container, but it does not by itself maintain several instances, replace a failed instance, or give all instances one stable address. Kubernetes adds that control layer.

Kubernetes uses **desired state**. You declare what should exist, such as three Beacon replicas, and Kubernetes continuously compares that declaration with what is actually running. If a pod disappears, Kubernetes creates a replacement.

The main objects in this tutorial are:

| Object | Purpose |
|---|---|
| Cluster | The complete Kubernetes environment |
| Node | A machine that runs pods |
| Pod | The smallest deployable unit, containing one or more containers |
| Deployment | Maintains a declared number of matching pods |
| Service | Gives a changing group of pods one stable network address |
| Manifest | A YAML file that declares the desired state of an object |

## Lab 1: Create your cluster

### Step 1: Create the cluster

Run:

```bash
k3d cluster create clo25 \
  --image rancher/k3s:v1.36.4-k3s1 \
  --port "8080:80@loadbalancer"
```

This command:

- names the cluster `clo25`
- selects the specified k3s/Kubernetes image
- maps port `8080` on your computer to port `80` on the cluster load balancer

The first creation can take a minute or two while images are downloaded. Successful output ends with a message similar to:

```text
Cluster 'clo25' created successfully!
```

If port 8080 is already in use, delete the incomplete cluster:

```bash
k3d cluster delete clo25
```

Then either stop the program using port 8080 or create the cluster with port 8081:

```bash
k3d cluster create clo25 \
  --image rancher/k3s:v1.36.4-k3s1 \
  --port "8081:80@loadbalancer"
```

### Step 2: Verify the node

```bash
kubectl get nodes
```

Expected shape:

```text
NAME                 STATUS   ROLES           AGE   VERSION
k3d-clo25-server-0   Ready    control-plane   ...   ...
```

`Ready` means the node can accept workloads. This small local cluster uses one node for both the control plane and application workloads.

If the node remains `NotReady` for more than a minute, give the container runtime at least 4 GB of memory, recreate the cluster, and check again.

### Step 3: Verify the kubectl context

`kubectl` can connect to several clusters. Its current context determines which cluster receives each command.

```bash
kubectl config current-context
```

Expected output:

```text
k3d-clo25
```

If another context is selected, switch explicitly:

```bash
kubectl config use-context k3d-clo25
```

### Step 4: Inspect system pods

```bash
kubectl get pods --namespace kube-system
```

You should see components such as CoreDNS, Traefik, the metrics server, and the local-path provisioner. Pods that briefly show `ContainerCreating` should become `Running` after the cluster finishes starting. One-time installation pods may correctly show `Completed`.

## Lab 2: Run Beacon in the cluster

Run all commands in this section from the repository root.

### Step 1: Build a versioned image

```bash
docker build \
  --file src/Beacon.Api/Dockerfile \
  --tag beacon:v1 \
  .
```

Confirm that the image exists:

```bash
docker images beacon
```

The versioned `v1` tag is intentional. The special `latest` tag normally gives Kubernetes an `Always` image-pull policy, which makes it try Docker Hub even when a local image was imported. A non-`latest` tag normally uses the local image when it is present.

### Step 2: Import the image into k3d

The cluster runs inside its own containers and cannot automatically see images stored by Docker on the host. Import Beacon:

```bash
k3d image import beacon:v1 --cluster clo25
```

Successful output reports that one image was imported into the cluster.

### Step 3: Run Beacon as a single Pod

The example manifest at `k8s/examples/pod.yaml` declares one Pod:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: beacon
  labels:
    app: beacon
spec:
  containers:
    - name: beacon
      image: beacon:v1
      ports:
        - containerPort: 8080
```

Apply it:

```bash
kubectl apply -f k8s/examples/pod.yaml
kubectl get pods
```

Wait until the Pod shows `1/1` under `READY` and `Running` under `STATUS`.

Test the application by forwarding a local port to the Pod:

```bash
kubectl port-forward pod/beacon 5001:8080
```

Leave that command running. In a second terminal, call Beacon:

```bash
curl http://localhost:5001/health
```

Beacon should return a successful health response. Stop port forwarding with `Ctrl+C`.

Now delete the Pod:

```bash
kubectl delete pod beacon
kubectl get pods
```

The Pod stays deleted because no controller is responsible for recreating it. This is why production workloads are normally managed by a Deployment rather than created as bare Pods.

## Lab 3: Manage Beacon with a Deployment

### Step 1: Apply the Deployment

The file `k8s/deployment.yaml` declares three replicas and selects pods with the label `app: beacon`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: beacon
spec:
  replicas: 3
  selector:
    matchLabels:
      app: beacon
  template:
    metadata:
      labels:
        app: beacon
    spec:
      containers:
        - name: beacon
          image: beacon:v1
          ports:
            - containerPort: 8080
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              memory: 256Mi
```

Apply it and inspect the objects it creates:

```bash
kubectl apply -f k8s/deployment.yaml
kubectl get deployments
kubectl get replicasets
kubectl get pods
```

The Deployment manages a ReplicaSet, and the ReplicaSet maintains three pods.

### Step 2: Observe self-healing

List the pods and copy one name:

```bash
kubectl get pods
```

Delete that pod:

```bash
kubectl delete pod <pod-name>
```

Then inspect the pods again:

```bash
kubectl get pods
```

A replacement appears because the Deployment still requires three replicas. To watch the transition live, run `kubectl get pods --watch` in one terminal while deleting a pod in another.

### Step 3: Scale the Deployment

Scale Beacon temporarily to five replicas:

```bash
kubectl scale deployment beacon --replicas 5
kubectl get pods
```

Return it to the desired state stored in the manifest:

```bash
kubectl apply -f k8s/deployment.yaml
kubectl get pods
```

Applying the manifest returns the replica count to three. This demonstrates why the version-controlled manifest should remain the source of truth.

### Step 4: Check the rollout

```bash
kubectl rollout status deployment beacon
```

The command should report that the Deployment successfully rolled out.

## Lab 4: Give the pods one address

Pod names and IP addresses change as pods are replaced. A Service selects pods by label and gives them a stable address.

### Step 1: Apply the Service

The file `k8s/service.yaml` declares a Service on port 80 and forwards traffic to port 8080 in every selected Beacon pod:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: beacon
spec:
  selector:
    app: beacon
  ports:
    - port: 80
      targetPort: 8080
```

Apply and inspect it:

```bash
kubectl apply -f k8s/service.yaml
kubectl get service beacon
```

### Step 2: Verify the selected endpoints

```bash
kubectl get endpointslices \
  --selector kubernetes.io/service-name=beacon
```

The endpoint count should correspond to the ready Beacon pods. The connection works because the Service selector `app: beacon` matches the labels in the Deployment's pod template.

### Step 3: Reach Beacon through the Service

```bash
kubectl port-forward service/beacon 5001:80
```

In a second terminal:

```bash
curl http://localhost:5001/health
```

Stop port forwarding with `Ctrl+C` after the request succeeds.

## Troubleshooting

Use the command that matches the question you need answered:

| Question | Command |
|---|---|
| What objects exist and what is their status? | `kubectl get pods` |
| Why did this Pod fail? | `kubectl describe pod <pod-name>` |
| What did Kubernetes do with the Deployment? | `kubectl describe deployment beacon` |
| What did the application write? | `kubectl logs <pod-name>` |
| What warnings happened recently? | `kubectl events --types Warning` |
| What is inside the running container? | `kubectl exec <pod-name> -- ls` |
| Which pods did the Service find? | `kubectl get endpointslices --selector kubernetes.io/service-name=beacon` |

Common states include:

- `Pending`: the Pod has not been scheduled or cannot start yet
- `ContainerCreating`: Kubernetes is preparing the container
- `ErrImagePull`: an image download failed
- `ImagePullBackOff`: Kubernetes is waiting before retrying a failed pull
- `CrashLoopBackOff`: the application repeatedly starts and exits
- `Running`: the Pod is running, although readiness should still be checked

If a local image cannot be found, confirm that the manifest uses `beacon:v1`, import that exact tag again, and recreate the affected pod.

## When you are done

Stop the cluster to release memory while preserving its contents:

```bash
k3d cluster stop clo25
```

Start it again later:

```bash
k3d cluster start clo25
```

Wait about 30 seconds before checking the pods.

Delete the cluster only when you no longer need it:

```bash
k3d cluster delete clo25
```

Deleting the cluster removes its Kubernetes objects. The YAML manifests remain in Git and can recreate the application in another cluster.

## Check yourself

- [ ] `kubectl get nodes` shows the local node as `Ready`.
- [ ] `kubectl config current-context` shows `k3d-clo25`.
- [ ] I can explain the difference between a Pod and a Deployment.
- [ ] I have seen the Deployment replace a deleted pod.
- [ ] The Deployment maintains three Beacon replicas.
- [ ] I can explain how the Service selector finds the Beacon pods.
- [ ] I can reach `/health` through the Service.
- [ ] I know which command to use when a pod does not run.

## Summary

You created a local Kubernetes cluster named `clo25` and used `kubectl` to inspect its node, context, and system components. You built Beacon as the versioned image `beacon:v1` and imported it into k3d so the local cluster could run it without an external registry.

A bare Pod demonstrated the smallest unit Kubernetes runs, as well as its main limitation: after deletion, it stayed deleted. The Deployment solved that problem by maintaining three replicas and replacing a deleted pod automatically. Resource requests and limits also documented the capacity each Beacon pod needs.

Finally, the Service selected pods with the shared `app: beacon` label and provided one stable endpoint in front of them. The finished flow is:

```text
request -> Service -> one of three Beacon pods
                    -> Deployment keeps the pod count at three
```

The manifests in `k8s/` are the reproducible source of truth. The cluster can be stopped, deleted, or replaced, while the application configuration remains versioned with the code.
