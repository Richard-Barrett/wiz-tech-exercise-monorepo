# Wiz Technical Exercise v4 — Mono-Repo (AWS Reference Implementation)

This repository deploys the full environment required by the **Wiz Technical Exercise v4**:
- Two-tier app: **containerized web app on Kubernetes** + **MongoDB on a VM**
- Web app exposed publicly via **Kubernetes Ingress** backed by a **cloud load balancer**
- **MongoDB is only reachable from the Kubernetes node network** (Security Group restriction)
- VM runs a **1+ year outdated Linux** release, **SSH exposed publicly**, and has **overly permissive IAM**
- MongoDB runs a **1+ year outdated version**, requires **DB authentication**
- Daily automated backups uploaded to **public-readable + publicly listable** object storage

> ⚠️ This environment is intentionally insecure per the exercise requirements. Deploy **only** in a disposable lab account.

## Quick Start (local)

### Prereqs
- AWS account + credentials (or GitHub OIDC role)
- `terraform` >= 1.6
- `kubectl`, `helm`
- `awscli`

### 1) Configure Terraform variables
Copy the example file and edit it:

```bash
cd infra/terraform
cp terraform.tfvars.example terraform.tfvars
```

You must provide:
- `aws_region`
- `name_prefix`
- `public_key_path` (SSH key used to access the MongoDB VM)
- `your_name` (used to write `wizexercise.txt` inside the app image)

### 2) Deploy infrastructure
```bash
make infra-init
make infra-apply
```

Terraform outputs:
- EKS cluster name
- MongoDB private IP / DNS
- S3 backup bucket name (intentionally public)
- App endpoint (after app deploy)

### 3) Configure kubectl
```bash
make kubeconfig
kubectl get nodes
```

### 4) Build and deploy the application
This will build the container image (with `wizexercise.txt` containing your name), push to ECR, and deploy to EKS.

```bash
make app-build-push
make app-deploy
```

### 5) Validate exercise requirements (demo-ready)
See: `scripts/demo_commands.md`

## Tear down
```bash
make infra-destroy
```

## Repo Layout
- `infra/terraform/` — Terraform for VPC, EKS (private nodes), MongoDB VM, public S3 backups, and security tooling
- `app/` — Node/Express todo app using MongoDB
- `app/k8s/` — Kubernetes manifests (Ingress, RBAC cluster-admin binding, etc.)
- `.github/workflows/` — Two pipelines: IaC deploy + app build/push/deploy (plus scans)
- `scripts/` — demo commands and helper scripts

## Notes on intentional weaknesses
The intentional weaknesses are implemented in Terraform (see `infra/terraform/main.tf` and security group/IAM resources):
- SSH open to the world on the Mongo VM
- EC2 instance role is overly permissive (EC2 create/run/etc.)
- S3 backup bucket is public-read + list
- App ServiceAccount is bound to cluster-admin

## Production hardening (talk track)
See `docs/production_hardening.md`.

---
**Author:** (edit)  
**Last updated:** 2026-01-31
