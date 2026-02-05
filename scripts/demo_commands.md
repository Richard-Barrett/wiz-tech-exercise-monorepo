# Demo Commands (Wiz Exercise v4)

## 1) Show kubectl works
```bash
kubectl get nodes
kubectl -n wizapp get pods,svc,ingress
```

## 2) Prove MongoDB is configured via environment variable (Kubernetes)
```bash
POD=$(kubectl -n wizapp get pod -l app=wizapp -o jsonpath='{.items[0].metadata.name}')
kubectl -n wizapp exec -it "$POD" -- printenv | grep MONGODB_URI
```

## 3) Prove wizexercise.txt exists in the running container image and contains your name
```bash
kubectl -n wizapp exec -it "$POD" -- ls -l /app/wizexercise.txt
kubectl -n wizapp exec -it "$POD" -- cat /app/wizexercise.txt
```

## 4) Prove app has cluster-wide admin (intentional)
```bash
kubectl get clusterrolebinding wizapp-cluster-admin -o yaml
```

## 5) Prove app works and data persists (browser)
- Browse to the ALB hostname shown in:
  ```bash
  kubectl -n wizapp get ingress wizapp -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'; echo
  ```
- Add a todo item in the UI, refresh, show it persists.

## 6) Prove MongoDB is not public but SSH is public
- In AWS Console: show Security Group inbound rules:
  - `22/tcp` from `0.0.0.0/0` (intentional weakness)
  - `27017/tcp` only from EKS node SG (restricted to Kubernetes network)

## 7) Prove backups are stored in public-readable/listable S3
- In AWS Console: show bucket policy allows public read/list
- Optional:
  ```bash
  aws s3 ls s3://$(terraform -chdir=infra/terraform output -raw backups_bucket_name)/
  ```

## 8) Show cloud native audit logging + detective controls
- EKS control plane logs enabled (CloudWatch)
- CloudTrail enabled
- EventBridge rule writes sensitive events to a CloudWatch log group

