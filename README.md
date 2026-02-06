# Wiz Tech Exercise Monorepo

[![app-build-push-ecr](https://github.com/Richard-Barrett/wiz-tech-exercise-monorepo/actions/workflows/app-build-push-ecr.yml/badge.svg)](https://github.com/Richard-Barrett/wiz-tech-exercise-monorepo/actions/workflows/app-build-push-ecr.yml)
[![infra-deploy](https://github.com/Richard-Barrett/wiz-tech-exercise-monorepo/actions/workflows/infra-deploy.yml/badge.svg)](https://github.com/Richard-Barrett/wiz-tech-exercise-monorepo/actions/workflows/infra-deploy.yml)
[![security-scans](https://github.com/Richard-Barrett/wiz-tech-exercise-monorepo/actions/workflows/security.yml/badge.svg)](https://github.com/Richard-Barrett/wiz-tech-exercise-monorepo/actions/workflows/security.yml)

This repository contains a small end-to-end deployment that provisions infrastructure on AWS and deploys an application to Kubernetes.

It includes:
- **Infrastructure as Code** using **Terraform**
- An **EKS** cluster and supporting AWS resources
- A sample **application** container image and Kubernetes manifests
- A **MongoDB** instance (configured via userdata)
- Scripts and Makefile targets to build, deploy, and verify resources

> This repo is intended for demonstration/testing purposes.

---

## Repository Structure

```
├───.github
│   └───workflows
├───app
│   ├───k8s
│   ├───public
│   └───src
├───docs
├───infra
│   └───terraform
└───scripts
```

---

## Prerequisites

- AWS credentials configured (able to create EKS/IAM/VPC/ECR/S3/etc.)
- Terraform installed (per `infra/terraform/versions.tf`)
- kubectl installed
- Docker installed (for local build + push)

---

## Quickstart

```bash
make infra-init
make infra-plan
make infra-apply
make kubeconfig
make app-build-push
make app-deploy
make app-status
```

---

## Verify `wizexercise.txt` in the running container

Requirement: the container image must include `wizexercise.txt` containing your name.  
In this project it is expected at:

- `/app/wizexercise.txt`

Verify:

```bash
kubectl get pods -n wizapp
kubectl exec -n wizapp -it <pod_name> -- sh -lc 'ls -l /app/wizexercise.txt && echo "-----" && cat /app/wizexercise.txt'
```

Expected output includes your name (e.g., `Richard Barrett`).

---

## Wiki

A full GitHub Wiki page set is provided in the `wiki/` folder of the downloadable artifact from ChatGPT.
Copy those files into your repo Wiki [Wiki](https://github.com/Richard-Barrett/wiz-tech-exercise-monorepo/wiki) to publish them.

---

## Dependabot

This repo includes a Dependabot config for:
- GitHub Actions workflows
- Terraform providers/modules
- NPM dependencies

See `.github/dependabot.yml`.
