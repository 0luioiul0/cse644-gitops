# CSE644 Assignment 03 — Submission Package

## Submission items

| Item | Value |
|---|---|
| Name | **Chi Zhang** |
| GitHub username | **0luioiul0** |
| Repository | **https://github.com/0luioiul0/cse644-gitops** |
| Kubernetes environment | **KinD v0.30.0** — Kubernetes v1.34.0, 1 control-plane + 2 workers, on Docker Engine 29.1.3 (Ubuntu 22.04 / WSL2, Windows 11) |
| GitOps tool selected | **Argo CD v3.5.0**, installed from the pinned upstream manifest |
| Container image and version | **`docker.io/luioiul/cse644-gitops-web:1.0.0`** and **`docker.io/luioiul/cse644-gitops-api:1.2.0`** — public on Docker Hub, referenced by pinned tag, never `:latest` |
| Monitoring images | `prom/prometheus:v3.13.2`, `grafana/grafana:13.1.3` |
| README | **[README.md](README.md)** |
| Assignment 01 / 02 repositories | [cse644-docker](https://github.com/0luioiul0/cse644-docker) · [cse644-k8s](https://github.com/0luioiul0/cse644-k8s) |

Application entry points, all on host port 8090 and separated by `Host` header:

| URL | What it is |
|---|---|
| <http://web.gitops.local:8090/> | the customized Nginx application from Assignment 01 |
| <http://api.gitops.local:8090/> | the Python application, port 8888 |
| <http://argocd.gitops.local:8090/> | Argo CD (anonymous read-only) |
| <http://grafana.gitops.local:8090/d/cse644-gitops> | the provisioned dashboard |
| <http://prometheus.gitops.local:8090/> | Prometheus |

---

## Required outcomes → evidence

| # | Required outcome | Evidence |
|---|---|---|
| 1 | Version-controlled application platform | the repository itself + [`evidence/02-repository.txt`](evidence/02-repository.txt) |
| 2 | GitOps deployment, controller creates and maintains the resources | [`evidence/04-gitops-deploy.txt`](evidence/04-gitops-deploy.txt) |
| 3a | A meaningful change made through Git and reconciled | [`evidence/06-git-driven-change.txt`](evidence/06-git-driven-change.txt) |
| 3b | Controller response when live state differs from Git | [`evidence/07-drift-reconciliation.txt`](evidence/07-drift-reconciliation.txt) |
| 4 | Controlled failure, diagnosis, and recovery through Git | [`evidence/08-failure-recovery.txt`](evidence/08-failure-recovery.txt) |
| 5 | Prometheus collecting, Grafana presenting, metrics responding to load | [`evidence/09-prometheus.txt`](evidence/09-prometheus.txt) · [`evidence/10-grafana.txt`](evidence/10-grafana.txt) |
| 6 | Validation and cleanup, with verification | [`evidence/11-cleanup.txt`](evidence/11-cleanup.txt) |

## Evidence expectations → where

| Expectation | Where |
|---|---|
| The Kubernetes environment | [`01-cluster.txt`](evidence/01-cluster.txt) — nodes, versions, add-ons, `readyz` |
| Repository and revision history | [`02-repository.txt`](evidence/02-repository.txt) — remote, log, tree, what Argo CD is reading |
| GitOps deployment status | [`04-gitops-deploy.txt`](evidence/04-gitops-deploy.txt) — two applies, then 9 + 14 objects created by the controller; every one carrying its tracking annotation |
| A Git-driven change | [`06-git-driven-change.txt`](evidence/06-git-driven-change.txt) — three commits, each observed by revision |
| Reconciliation of live-state difference | [`07-drift-reconciliation.txt`](evidence/07-drift-reconciliation.txt) — the same drift with selfHeal off and on |
| Controlled failure and Git-based recovery | [`08-failure-recovery.txt`](evidence/08-failure-recovery.txt) — `Synced` + `Degraded`, then `git revert` |
| Application access | [`05-app-access.txt`](evidence/05-app-access.txt) — both applications through the ingress, identified by Pod, node and version headers |
| Prometheus collection | [`09-prometheus.txt`](evidence/09-prometheus.txt) — every target, then a shaped workload read back out |
| Grafana visualization | [`10-grafana.txt`](evidence/10-grafana.txt) — 16 panels, every query returning data |
| Cleanup | [`11-cleanup.txt`](evidence/11-cleanup.txt) — cascade delete, then the checks that would fail if anything survived |
| Image build and push | [`00-image-build-and-push-1.0.0.txt`](evidence/00-image-build-and-push-1.0.0.txt) · [1.1.0](evidence/00-image-build-and-push-1.1.0.txt) · [1.2.0](evidence/00-image-build-and-push-1.2.0.txt) |
| Screenshots | [`evidence/screenshots/`](evidence/screenshots/) — both applications, the Prometheus targets page and graph, and the Grafana dashboard with data on it. There is no Argo CD screenshot: its UI streams over an EventSource, so headless Chromium never reaches an idle state and captures only a "Loading…" shell. The controller's evidence is the transcripts, which the assignment accepts and which say more. |

---

## The four results worth reading

**A ConfigMap-only commit left the application unchanged while Argo CD
correctly reported `Synced` and `Healthy`.** `envFrom` reads a ConfigMap once,
at container start. The cluster matched Git; the behaviour did not.

**One commit, two workloads, opposite outcomes.** A tag that was never pushed
took the api down completely (`Recreate`, so the working Pod was deleted before
the replacement failed to start) while web kept serving on HTTP 200
(`RollingUpdate` with `maxUnavailable: 0`, so no working replica was removed
for one that never became ready). Argo CD reported `Synced` and `Degraded`
simultaneously — sync status is agreement, health status is whether it works.

**`selfHeal: false` does not mean "never revert drift".** Argo CD suppresses
the automated sync only at a revision it has already attempted. A commit that
does not touch the synced path produces no sync, so the Application sits at a
revision it has never applied, and the next divergence is treated as an
unsynced revision rather than as drift — triggering a full sync that erases it.
Three runs of the drift demonstration were wrong before the controller log made
this visible.

**A latency metric that measured the client's idle time.** The request timer
started before the blocking keep-alive read, so the application reported a
13.2 s mean for `/metrics` against a 15 s scrape interval while actually
answering in about 3 ms. Fixed in api 1.2.0. Two scrape jobs also reported
targets `up` while collecting nothing at all.

All four, and the rest, are written up in
[README § What went wrong while building this](README.md#what-went-wrong-while-building-this).

---

## Security statement

No password, access token, kubeconfig file, private key, API key or secret
value is committed to this repository or appears in any evidence transcript.
Both Secrets used by the workloads are generated at deploy time and stay out of
version control; the transcripts print only their key names and byte counts.
The Argo CD CLI runs in `--core` mode against the existing kubeconfig, so no
session token or admin password is used anywhere, and the initial admin Secret
is left untouched.
