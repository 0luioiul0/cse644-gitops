# CSE644 Assignment 03 — GitOps and Application Observability

The two applications from Assignments 01 and 02 — a customized Nginx web
application and a Python application on port 8888 — operated as a
GitOps-managed workload: Argo CD reconciles them from this repository, a
Prometheus and Grafana stack deployed the same way measures them, and every
change, every failure and every recovery in this document happened through a
commit.

Everything under [`evidence/`](evidence/) is a transcript of a real run against
the cluster described below. Each transcript prints the command before its
output, so any line can be copied and re-run.

| | |
|---|---|
| Student | **Chi Zhang** |
| GitHub username | **0luioiul0** |
| Repository | https://github.com/0luioiul0/cse644-gitops |
| Local Kubernetes environment | **KinD v0.30.0** — 1 control-plane + 2 workers, Kubernetes v1.34.0 |
| Container engine | Docker Engine 29.1.3 on Ubuntu 22.04 (WSL2), Windows 11 |
| GitOps tool | **Argo CD v3.5.0** |
| Container images | `luioiul/cse644-gitops-web:1.0.0`, `luioiul/cse644-gitops-api:1.2.0` |
| Monitoring images | `prom/prometheus:v3.13.2`, `grafana/grafana:13.1.3` |
| Assignment 01 / 02 repositories | [cse644-docker](https://github.com/0luioiul0/cse644-docker) · [cse644-k8s](https://github.com/0luioiul0/cse644-k8s) |

---

## Architecture

```
   GitHub: 0luioiul0/cse644-gitops (main)
         │
         │  Argo CD polls every 3 minutes, or on demand via the refresh annotation
         ▼
   ┌──────────────────────────────────────────────────────────────────┐
   │ argocd namespace          Argo CD v3.5.0                         │
   │   Application cse644-root ──── path gitops/apps ─────────┐       │
   └──────────────────────────────────────────────────────────┼───────┘
                    │ declares                                │
        ┌───────────┴────────────┐                            │
        ▼                        ▼                            │
   Application                Application                     │
   cse644-platform            cse644-monitoring               │
   path k8s/                  path monitoring/                │
        │                        │                            │
        ▼                        ▼                            │
   ┌─────────────────────┐  ┌──────────────────────────┐      │
   │ cse644-gitops ns    │  │ cse644-monitoring ns     │      │
   │  Deployment web ×3  │  │  Prometheus + 2Gi PVC    │◀─────┘
   │  Deployment api ×1  │  │  Grafana (provisioned)   │  scrapes argocd-metrics
   │  PVC api-data       │  │                          │
   │  ConfigMaps, Svcs   │  │  scrapes ─────────────┐  │
   │  Ingress            │  │   • annotated Pods    │  │
   └──────────┬──────────┘  │   • kubelet cAdvisor  │  │
              │             └───────────────────────┼──┘
              │                                     │
              └─────────────────────────────────────┘
                         ingress-nginx (shared, from Assignment 02)
                         host port 8090, routed by Host header
```

Five host names all arrive on port 8090 and are separated by `Host` header
alone: `web.gitops.local`, `api.gitops.local`, `argocd.gitops.local`,
`grafana.gitops.local`, `prometheus.gitops.local`.

**The root Application is the only thing that knows what is deployed.** It
syncs `gitops/apps/`, a directory containing the AppProject and the two child
Applications. "What runs on this cluster, and with what sync policy" is
therefore a reviewable file, not a command somebody ran once — and changing a
sync policy means editing `gitops/apps/10-platform.yaml` and pushing, because
`argocd app set` would itself be drift and would be reverted.

---

## Prerequisites

| Requirement | Version used here | Notes |
|---|---|---|
| Docker | 29.1.3 | KinD needs only a Docker daemon |
| kind | v0.30.0 | the cluster from Assignment 02 is reused as-is |
| kubectl | v1.36.3 | |
| argocd CLI | v3.5.0 | installed by `scripts/03_argocd_install.sh` into `~/.local/bin` |
| Free host ports | 8090 | mapped to the control-plane node by Assignment 02's `kind/cluster.yaml` |
| Memory | ~4 GB | cluster, Argo CD, Prometheus, Grafana |

Nothing here needs root. The cluster itself, ingress-nginx and MetalLB come
from [cse644-k8s](https://github.com/0luioiul0/cse644-k8s) `scripts/01_cluster_up.sh`.

---

## Deployment

```bash
git clone https://github.com/0luioiul0/cse644-gitops.git
cd cse644-gitops

bash scripts/03_argocd_install.sh   # Argo CD, its ingress, the CLI
bash scripts/04_bootstrap.sh        # two kubectl applies, and nothing else ever
```

`04_bootstrap.sh` performs exactly two `kubectl apply` calls — the AppProject,
then the root Application — and creates the two Secrets that are deliberately
not in Git. Everything else in the cluster is created by Argo CD from this
repository. The order is not arbitrary: Argo CD refuses to admit an Application
whose project does not exist, and the project is declared inside the very
directory the root Application syncs, so applying it once by hand breaks that
circle.

To reproduce every demonstration and regenerate `evidence/`:

```bash
bash scripts/run_all.sh
```

### Images

Assignment 02 side-loaded images with `kind load docker-image`. That cannot
work here. Argo CD's job is to make the cluster match Git, and if the image a
manifest names exists only in one machine's Docker daemon then the cluster
state depends on something Git has no knowledge of. Both images are pushed to
Docker Hub and referenced by pinned tag; nothing uses `:latest`.

```bash
bash scripts/00_build_images.sh 1.2.0 api    # build and push one component
```

The component list matters. A tag is a claim that something changed, so an
api-only release does not push an identical `web` image under a new tag.
`APP_VERSION` is baked in at build time and never set in a manifest, so the tag
in Git, the OCI label on the image and the value the process reports cannot
disagree.

---

## Validation

```bash
# the applications
curl -H 'Host: web.gitops.local' http://localhost:8090/
curl -H 'Host: api.gitops.local' http://localhost:8090/api/info

# what Argo CD thinks
argocd --core --kube-context argocd-core app list
kubectl -n cse644-gitops get deploy,svc,ingress,pvc

# the metrics the dashboard is built on
curl -H 'Host: api.gitops.local' http://localhost:8090/metrics | grep '^cse644_api'
```

Argo CD UI: <http://argocd.gitops.local:8090/> · Grafana:
<http://grafana.gitops.local:8090/d/cse644-gitops> · Prometheus:
<http://prometheus.gitops.local:8090/>

Both UIs allow anonymous read-only access so they can be reviewed and
screenshotted without a password existing anywhere in this repository. The
cluster listens on localhost only; this would not be acceptable on a reachable
network.

---

## GitOps workflow, failure, and recovery

### A change through Git — [`evidence/06-git-driven-change.txt`](evidence/06-git-driven-change.txt)

Three commits, because the first teaches something the other two cannot.

| commit | change | result |
|---|---|---|
| 1 | `APP_MESSAGE` in the ConfigMap | **Synced, Healthy, and the page does not change.** Same Pods, same start times. |
| 2 | a Pod-template annotation | new ReplicaSet, fleet rolled, page changes. Observed **11s** after the push. |
| 3 | api image `1.0.0` → `1.1.0` | new version live, `cse644_api_notes_bytes` appears, volume intact |

Commit 1 is the most common way a GitOps deployment silently does nothing.
`envFrom` reads a ConfigMap once, at container start. Argo CD updated the
object it was asked to update and correctly reported success; it has no way to
know that this particular object is only read at boot. Commit 2 changes
something inside `spec.template`, which changes the Pod template hash, which is
what actually rolls a Deployment. The annotation carries no meaning to
Kubernetes — its only job is to be different.

### Drift — [`evidence/07-drift-reconciliation.txt`](evidence/07-drift-reconciliation.txt)

The same drift twice: `kubectl scale --replicas=1` plus a `kubectl patch` of
the ConfigMap, once with `selfHeal: false` and once with it on.

| | selfHeal off | selfHeal on |
|---|---|---|
| detected | yes — `OutOfSync`, and `argocd app diff` names both differences | yes |
| corrected | **no.** `replicas=1` held for a full minute | yes, **~900 ms** |
| a deleted Deployment | — | recreated in **208–880 ms** |

Detection and correction are two different behaviours and two different
settings. With `selfHeal: false` Argo CD reports the truth and waits for a
human; `argocd app sync` then restores both objects.

### Controlled failure and recovery — [`evidence/08-failure-recovery.txt`](evidence/08-failure-recovery.txt)

One commit points both images at `1.9.9-tag-that-does-not-exist`. The
interesting part is that the two workloads do not fail the same way.

| | web | api |
|---|---|---|
| strategy | RollingUpdate, `maxUnavailable: 0` | Recreate (ReadWriteOnce volume) |
| during the failure | **HTTP 200**, serving the old image | **HTTP 503** |
| EndpointSlice | 3 ready + 1 not-ready | 1 address, not ready |
| outcome | no outage | real outage |

Same commit, same registry error, opposite outcomes — decided entirely by a
rollout strategy that was chosen for a storage constraint. Argo CD reported
**`Synced` and `Degraded` at the same time**: Git asked for an image that does
not exist, and the cluster now faithfully asks for an image that does not
exist. Sync status is about agreement; health status is about whether the
result works. Alerting on sync status alone would have missed this entirely.

Recovery is `git revert` of the breaking commit, pushed. Argo CD observed it in
**2 seconds** and both Deployments rolled back to healthy. `kubectl set image`
would have fixed the cluster in about two seconds too, and would have been the
wrong answer: Git would still hold the broken tag, selfHeal would put it back,
and the incident would be invisible afterwards. The revert is a new commit, so
the whole incident stays readable in the history.

---

## Observability approach

Prometheus scrapes three jobs and Grafana renders one provisioned dashboard;
both are deployed by Argo CD from `monitoring/`, so the monitoring
configuration is under the same review and rollback as the application.

| job | what it answers |
|---|---|
| `kubernetes-pods` | the application's own metrics, discovered from Pod annotations rather than listed by hand |
| `kubelet-cadvisor` | container CPU and memory — "is the workload resource-starved", which application metrics cannot answer |
| `argocd` | the GitOps controller measuring itself; `argocd_app_info` carries `sync_status` and `health_status` |

The api application is instrumented by hand in the standard library — no
client library, so the image stays dependency-free:

| metric | why it is there |
|---|---|
| `cse644_api_requests_total{method,route,status}` | rate, and the error ratio from the `status` label |
| `cse644_api_request_duration_seconds` | a histogram, so quantiles are computed at query time from bucket counts rather than pre-averaged in the app |
| `cse644_api_requests_in_flight` | concurrency — rises when work queues, which an averaged latency figure hides |
| `cse644_api_notes_stored` / `_bytes` | application state on the PersistentVolume: count, and how full the claim is getting |
| `cse644_api_healthy`, `cse644_api_build_info` | liveness as a series, and the running version as a label |

Route labels come from a fixed allow-list, so a scan for `/wp-admin.php` is
recorded as `route="other"` and cannot create unbounded label cardinality —
the classic way an instrumented service takes its own monitoring down.

### What the measurements actually showed — [`evidence/09-prometheus.txt`](evidence/09-prometheus.txt)

A generated workload with a deliberate shape — baseline, burst, slow requests,
errors, CPU burn — and then the same shape read back out of Prometheus:

| | |
|---|---|
| peak request rate | **38.7 req/s**, against a baseline near 0.3 |
| latency p50 / p90 / p99 | **3 ms / 10 ms / 1.34 s** |
| slowest routes | `/api/work` **663 ms**, `/api/cpu` **408 ms**, everything else ~3 ms |
| 5xx ratio over the run | **1.9%**, with 404s kept separate from 500s by the `status` label |
| peak container CPU | api **0.276 cores** during the burn; web **0.002** |
| notes on the volume | **88**, monotonically increasing across every Pod replacement in this assignment |
| Argo CD | 3 applications, `Synced` / `Healthy` |

Two of those columns exist to be read together. During the slow-request phase
the request rate *falls* while latency and in-flight *rise* — the signature of
work queueing rather than of traffic disappearing. On a request-rate graph
alone those two look identical. And container CPU stays flat through that same
phase while latency is at its worst, because the workload is waiting rather
than computing; that distinction is the reason an application metric and an
infrastructure metric are on the same dashboard.

All 16 dashboard panel queries return data —
[`evidence/10-grafana.txt`](evidence/10-grafana.txt) runs each one through
Grafana's own query API rather than trusting the screenshot.

---

## Technical decisions and limitations

**Argo CD rather than Flux.** Both reconcile Git into a cluster and either
would satisfy the assignment. Argo CD ships a server that renders the
live-versus-desired diff, the sync status and the health of every managed
object as one view, and three of the required demonstrations are about exactly
that difference.

**Secrets are not in Git, and that has a cost.** A Kubernetes Secret is
base64-encoded, not encrypted; committing one to a public repository publishes
it. `api-secret` and `grafana-admin` are generated at bootstrap and never
leave the cluster. The honest consequence is that these two objects are outside
GitOps control — Argo CD can neither recreate them nor detect drift in them.
The production answers are Sealed Secrets or the External Secrets Operator;
both were out of scope for a local cluster.

**Argo CD is not managed by Argo CD.** A controller that reconciles its own
installation cannot recover from a bad commit to that installation.

**The ingress controller has no metrics.** There was a fourth scrape job for
per-host request rate and latency, and it collected nothing while reporting the
target `up` — this cluster's ingress-nginx, installed by Assignment 02 from the
kind deploy manifest, runs without metrics enabled, so `:10254` serves 128
lines of Go runtime statistics and not one `nginx_ingress_controller_*` series.
Enabling it means editing a Deployment this repository does not own, which is
precisely the unmanaged change the assignment argues against. The job was
removed and HTTP rate and latency come from the application's own
instrumentation instead.

**No webhook.** Argo CD learns about commits from a GitHub webhook in
production. A cluster on a laptop has no address GitHub can reach, so it falls
back to polling every three minutes. The scripts set the same refresh
annotation the UI's REFRESH button sets; that is the honest local stand-in.

**Plain HTTP.** `server.insecure=true` hands TLS termination to the ingress,
which here means plain HTTP on localhost.

**One replica of Prometheus and Grafana, 12h retention, 2Gi.** Enough to keep
a demonstration's history across a Pod restart, small enough for a laptop.

### What went wrong while building this

The failures were more instructive than the successes, and the fixes are in the
history rather than tidied away.

**A template manifest in a synced directory is not a template.**
`k8s/21-api-secret.example.yaml` was a valid Secret manifest named `api-secret`
sitting in the directory the platform Application syncs, so Argo CD applied it
and overwrote the real generated key with the placeholder string — while the
file's own comment claimed it was never applied. Renamed to `.yaml.example`,
which is outside the set of files Argo CD parses.

**Transcripts that lied.** `commit_push` ran `git push` and carried on
regardless of the result. On this machine the push fails — the clone's
credential helper shells out to the Windows GitHub CLI and this WSL2 distro has
interop unregistered, so it cannot execute at all — and a run produced three
failed pushes followed by pages of confident output about a deployment that
never happened. Every commit is now verified against `git ls-remote`, and the
script aborts rather than continue.

**`selfHeal: false` does not mean "never revert drift".** Argo CD skips the
automated sync only when it has *already attempted* a sync at the current
revision. The commit that disables selfHeal touches `gitops/apps/` and not
`k8s/`, so no sync runs for it, and the Application reports `Synced` at a
revision it has never applied. The next divergence is then judged as an
unsynced revision rather than as drift, and the controller performs a *full*
sync that erases it — indistinguishable from selfHeal working unless you read
the controller log, where a real self-heal names the resource it repairs and
carries a `SelfHealAttemptsCount`. Three runs of the drift demonstration were
wrong before that was understood.

**A latency metric that measured the client's idle time.** The request timer
started at the top of `handle_one_request`, and
`BaseHTTPRequestHandler.handle_one_request` *begins* by blocking on `readline()`
for the next request. On a keep-alive connection that block lasts until the
client's next request, so the application reported a **13.2 s** mean for
`/metrics` against a 15 s scrape interval, with p99 pinned to the top histogram
bucket, while every request was answered in about **3 ms**. `in_flight` had the
same flaw and counted parked connections as work. Fixed in 1.2.0 by starting
the clock in `parse_request`.

**`up == 1` means the scrape succeeded, not that the data exists.** Two jobs
reported healthy targets and collected nothing useful: the ingress controller
above, and the `argocd` job, which kept Pods with a container port named
`metrics` and so found only the ApplicationSet controller.
`argocd-application-controller-0` declares no container ports at all, so Pod
discovery can never reach it — its metrics are only available through the
`argocd-metrics` Service.

**A query window wider than the thing being measured.** The observability
queries used `[15m]` for a 4.5-minute workload, which reached back into the
previous api Pod — one running the version with the broken timer — and reported
mean latencies that were arithmetic over two different applications.

**Deleting the AppProject before its Applications deadlocks both.** An
Application carrying the resources finalizer cannot finish deleting unless the
controller can resolve its project; delete the project first and the
Application hangs in `Terminating` forever while the project waits on the
Application. `cleanup.sh` now refuses to remove the project while any
Application still exists.

**The Argo CD UI cannot be screenshotted headlessly, so it is not.**
`--virtual-time-budget` never elapses on a page holding an EventSource open to
stream application status, so Chromium runs until something kills it and writes
no file; forcing it with `--timeout` produces the navigation shell with
"Loading..." where the application list should be, identical at 12s and at 35s.
An image of a spinner is worse than no image. The captures were removed rather
than left to fail on every run, and the transcripts carry that evidence better
anyway — `evidence/04` lists every object with its tracking annotation,
`evidence/07` has the live-versus-desired diff as text, `evidence/08` has
`Synced` and `Degraded` together. The Grafana dashboard, which is a plain XHR
application, captures fine.

**Two smaller ones.** The Argo CD install manifest needs `--server-side`,
because the `applicationsets` CRD schema exceeds the 262144-byte limit on the
annotation a client-side apply uses. And `kubectl logs -f` dies instantly on
this host — `fs.inotify.max_user_instances` is 128 and exhausted — which one
run read as the load generator having finished, so it queried Prometheus thirty
seconds into a four-minute workload and then deleted the Pod mid-run.

---

## Cleanup

```bash
bash scripts/cleanup.sh          # remove the assignment, keep Argo CD
bash scripts/cleanup.sh --all    # also remove Argo CD itself
```

Deleting the root Application cascades: its finalizer removes the two child
Applications, whose finalizers remove every object they created — including
both namespaces, because the namespaces are themselves manifests in this
repository. The script then verifies removal rather than assuming it, and
checks the things a namespace deletion does *not* take with it: the ClusterRole
and ClusterRoleBinding Prometheus needed, PersistentVolumes, and the two
Secrets. Verification is in
[`evidence/11-cleanup.txt`](evidence/11-cleanup.txt).

What it deliberately does not touch: the KinD cluster, ingress-nginx, MetalLB,
and the `cse644` namespace belonging to Assignment 02. Other people's
containers run on this Docker host, so nothing here calls
`docker system prune`.

---

## Repository layout

```
.
├── apps/
│   ├── web/                 customized Nginx application (from Assignment 01)
│   └── api/                 Python application, port 8888, hand-instrumented
├── k8s/                     the application platform, synced by cse644-platform
├── monitoring/              Prometheus and Grafana, synced by cse644-monitoring
├── gitops/
│   ├── apps/                AppProject + the two child Applications
│   └── bootstrap/           the only two files ever applied by hand
├── scripts/                 one script per demonstration; all write to evidence/
├── evidence/                captured transcripts and screenshots
├── SUBMISSION.md            the submission package
└── README.md
```

---

## Security

No password, access token, kubeconfig, private key, API key or secret value is
committed to this repository or appears in any evidence transcript. The two
Secrets are generated at deploy time and stay out of version control; the
transcripts print only key names and byte counts. The Argo CD CLI runs in
`--core` mode, talking to the Kubernetes API with the existing kubeconfig, so
no session token or admin password is used anywhere — the initial admin Secret
is left untouched. `.gitignore` blocks kubeconfigs, `.env` files, key material
and Secret manifests. If a value is ever exposed, the response is to rotate it:
a value that has been disclosed stays disclosed no matter what is deleted
afterwards.
