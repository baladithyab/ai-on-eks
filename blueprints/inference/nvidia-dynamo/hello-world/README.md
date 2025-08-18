# Hello World Example

A simple CPU-only example that demonstrates basic Dynamo functionality without requiring GPUs. Perfect for testing your Dynamo platform deployment.

## Architecture

```text
Client Requests → Frontend → Hello World Worker
```

This example creates a basic service that responds to requests with a simple greeting.

## Prerequisites

- Dynamo platform deployed in your EKS cluster
- `dynamo-cloud` namespace with secrets configured

## Deployment

Deploy using kubectl:

```bash
kubectl apply -f hello-world.yaml -n dynamo-cloud
```

Or use the main deployment script:

```bash
cd ..
./deploy.sh hello-world
```

## Testing

Once deployed, test the service:

```bash
# Port forward to the service
kubectl port-forward svc/hello-world-frontend 8000:8000 -n dynamo-cloud

# Test the health endpoint
curl http://localhost:8000/health

# Test the hello endpoint (if available)
curl http://localhost:8000/hello
```

## Cleanup

Remove the deployment:

```bash
kubectl delete dynamographdeployment hello-world -n dynamo-cloud
```