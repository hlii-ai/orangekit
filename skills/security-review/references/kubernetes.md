# Containers and clusters — OWASP Kubernetes Top 10 (2022)

<!-- Inspired by: davila7/claude-code-templates `owasp-security` (MIT · Copyright (c) 2025 Daniel (San) Ávila)
     Canonical content: OWASP Kubernetes Top Ten (2022) — K01:2022 through K10:2022. -->

**Read only when the project deploys on K8s.** If manifests, Helm charts or IaC are in the repository, it applies.
If containers are used but not K8s, K01, K02 and K08 alone are enough.

| ID | Name | What to check |
| --- | --- | --- |
| **K01:2022** | Insecure Workload Configurations | `runAsNonRoot: true` · `allowPrivilegeEscalation: false` · `readOnlyRootFilesystem: true` · `privileged: false` · capabilities `drop: [ALL]` · hostPath/hostNetwork/hostPID unused |
| **K02:2022** | Supply Chain Vulnerabilities | Is the image tag **pinned to a digest** rather than `latest`. Base image provenance and scanning. Signature verification |
| **K03:2022** | Overly Permissive RBAC | `cluster-admin` bindings · wildcards (`verbs: ["*"]` · `resources: ["*"]`) · default ServiceAccount auto-mount (`automountServiceAccountToken: false`) |
| **K04:2022** | Lack of Centralized Policy Enforcement | Are the items above **enforced** by admission control, or do they rely on review alone |
| **K05:2022** | Inadequate Logging and Monitoring | Is the audit log on and retained. Is there alerting on permission denials and exception events (same axis as A09) |
| **K06:2022** | Broken Authentication | Are human and workload credentials short-lived. Are there no static tokens or shared kubeconfigs |
| **K07:2022** | Missing Network Segmentation | Is there a default-deny NetworkPolicy. Is cross-namespace traffic only what was explicitly opened |
| **K08:2022** | Secrets Management Failures | Do you know a Secret is merely base64, not encryption. Encryption at rest in etcd · an external secret manager · file mounts over environment variables · no plaintext Secrets in Git |
| **K09:2022** | Misconfigured Cluster Components | kubelet anonymous access · etcd exposure · API server flags · dashboard exposure |
| **K10:2022** | Outdated Components | Are the cluster, node, CNI and controller versions within the supported range |

**Where this meets the harness**: the IAM policy rows on the `guides/backend/aws-container` and
`gcp-serverless` axes already look at the same axis as K03 (no excessive permission grants). Where that is canonical, do not rule on it again here.
