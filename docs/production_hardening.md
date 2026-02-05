# Production Hardening Plan (talk track)

This lab intentionally violates best practices. In a real production rollout, I would:

## Identity & Access
- Remove cluster-admin binding; use least privilege Roles/RoleBindings per namespace/workload.
- Use IRSA for controllers and workloads; no broad instance role permissions.
- Constrain CI roles with permission boundaries + conditions (tags, resource ARNs, source IP where possible).

## Network
- Remove public SSH, enforce SSM Session Manager, add MFA + short-lived credentials.
- Put MongoDB behind a private endpoint and/or managed database service; no direct VM DB.
- Add NetworkPolicies in Kubernetes to restrict pod-to-pod and egress.

## Data & Storage
- Keep backup buckets private with bucket owner enforced and Block Public Access enabled.
- Encrypt data at rest (KMS) and in transit (TLS).
- Add retention, lifecycle, and immutable backups (Object Lock) where appropriate.

## Supply Chain / CI/CD
- Require signed commits, protected branches, mandatory checks (IaC scan + image scan).
- Use SBOMs, vulnerability gating, provenance (SLSA), and image signing (cosign).
- Separate build and deploy roles; deployments require approvals.

## Observability & Security Monitoring
- Centralize logs (CloudWatch/ELK), enable EKS audit logging, CloudTrail org trails.
- Enable GuardDuty, Security Hub, and Config rules with ticketing/alerting integration.
