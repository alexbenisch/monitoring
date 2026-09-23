---
title: "Scenario 05 — Jenkins CI/CD: plan for 2026-09-22"
author: "Alex Benisch"
date: 2026-09-21
geometry: "margin=1.5cm"
papersize: a4
---

# Scenario 05 — Jenkins CI/CD for a simple Java app

Numbered 05 to leave the planned 03 (traces) and 04 (Argo CD) alone; renaming
the directory later costs nothing.

## Progress

| Block | State | Bead |
|---|---|---|
| 1. Resize the host | **done** 2026-09-23 — `cpx42`, minikube cap 6144 → 13312 MiB | — |
| 2. The Java app | **done** — builds, tests, deployed by hand to `apps`, on the tailnet, scraped by Prometheus | — |
| Where hello-java lives | **open, and blocks everything below** | `obs-m23` |
| 3. Jenkins via Helm + JCasC | open | `obs-96f` |
| 4. Pipeline v1: build and test | open | `obs-khz` |
| 5. Pipeline v2: image with Kaniko | open | `obs-958` |
| 6. Pipeline v3: deploy and smoke-test | open | `obs-ezm` |
| 7. Jenkins metrics into Prometheus | open | `obs-4nc` |
| 7. Alloy to collect `apps` and `cicd` logs | open | `obs-17d` |

`bd ready` is the live version of this table. The timetable below is kept as
written, since the estimates are worth checking against reality.

**What block 2 proved, so a later failure is attributable:** the manifests are
known good. `hello-java` is running two replicas in `apps`, answering on the
tailnet, with both probes green and `serviceMonitor/apps/hello-java/0` up in
Prometheus. Jenkins therefore only has to automate a path that already works,
and `GET /hello` still reports `"build":"dev"` — the field that must change to
a build number on the first successful pipeline run.

---

## 1. Hardware: resize, don't provision a second server — DONE

**Done 2026-09-23.** Applied in place: `0 added, 1 changed, 0 destroyed` in
74 seconds, disk held at 160 GB by `keep_disk`, so it remains reversible. The
minikube cap was raised separately with `docker update` — no cluster restart
was needed, since CPU had never been capped at the container level.

The reasoning is kept below because the arithmetic is the reusable part.

**Verdict: the current server is not enough once scenario 02 is running, but a
second vServer is the wrong fix. Resize `obs-lab` from `cpx32` to `cpx42`.**

### The numbers

Measured on 2026-09-21, with scenario 01 running and scenario 02 **not yet
deployed**:

| | |
|---|---|
| Node allocatable (what the scheduler believes) | 7745 MiB |
| Actually in use | 3264 MiB (42%) |
| CPU in use | 328m of 4000m (8%) |

CPU is not the constraint and will not become one — a Maven build of a small
app uses a core or two for ninety seconds. **Memory is the whole question.**

Projected additions, using realistic RSS rather than the chart defaults:

| Component | Realistic memory |
|---|---|
| Scenario 02: Loki + Alloy + batch-worker + tailnet proxy | 0.9 – 1.2 GiB |
| Jenkins controller (chart *limit* defaults to 4 GiB — cap it) | 1.0 – 1.5 GiB |
| Agent pod during a Maven build (JNLP + maven containers) | 1.0 – 1.5 GiB |
| Kaniko image build, if it runs concurrently | +0.5 – 1.0 GiB |

Peak on a build day: **~7 GiB.** Against the 7.56 GiB Kubernetes advertises
that is already 93% before Kaniko, and the kubelet evicts by usage — Grafana
(520 MiB) and Prometheus (396 MiB) go first, so you would lose the
observability stack every time a build ran. Against the ceiling that actually
applies, measured below, it simply does not fit.

### The catch that makes it worse — now confirmed

`scenario-01-metrics/scripts/00-bootstrap.sh` starts minikube with
`--memory=6144` on the docker driver. The kubelet reads `/proc/meminfo`, which
is not namespaced, so it **advertises the host's 7.56 GiB while the container
is hard-capped at 6 GiB**. Verified on the host:

```
$ docker inspect obs-lab --format '{{.HostConfig.Memory}}'
6442450944          # exactly 6 GiB
```

So the real ceiling is **6144 MiB, not 7745**, and the scheduler does not know
it. Redo the arithmetic against the number that actually applies:

| | Running total |
|---|---|
| Real ceiling (cgroup cap on the minikube container) | **6144 MiB** |
| In use today | 3264 MiB |
| + scenario 02 | ~4.3 GiB — 1.8 GiB left |
| + Jenkins controller | ~5.5 GiB — 0.6 GiB left |
| + one Maven build agent | **~7.0 GiB — over the cap** |

Jenkins plus a single build does not fit today, and the failure would not be a
clean "insufficient memory" from the scheduler. The scheduler thinks there is
room, places the pod, and the container runtime OOM-kills whatever crosses the
cgroup limit — which is why this is worth knowing before rather than after.

The resize is therefore not optional, and **raising minikube's `--memory` is
the part people forget**: growing the server alone changes nothing, because
the 6 GiB cap travels with the profile.

### Why not a second vServer

A separate build host is the more realistic topology, and it is still the
wrong call for tomorrow:

- Two `cpx32` cost roughly what one `cpx42` costs, so there is no saving.
- Cross-host image delivery needs a real registry and TLS. `minikube image
  load` does not reach another machine.
- Another Terraform resource, another tailnet node, another cloud-init, another
  thing to debug — all of it competing with the actual goal, which is learning
  Jenkins pipelines.

Revisit it at scenario 04, where a separate cluster is genuinely part of the
Argo CD story.

### Doing the resize

`obs-lab` is Terraform-managed, so do this **through Terraform**, not the CLI.
Resizing with `hcloud server change-type` would leave state drift that the next
apply tries to "correct".

In `infra/main.tf`:

```hcl
resource "hcloud_server" "lab" {
  server_type = var.server_type   # -> "cpx42"

  # Keep the 160 GB disk. Hetzner cannot shrink a disk, so a resize that
  # grows it to 320 GB is a ONE-WAY DOOR - you could never go back to cpx32.
  # Keeping the disk makes the whole change reversible.
  keep_disk = true
}
```

and set `server_type = "cpx42"` (8 vCPU / 16 GB, confirmed orderable in `nbg1`
by today's `hcloud` workflow run).

> **Read the plan output before applying.** A `server_type` change should be an
> in-place resize: power off, resize, power on, a couple of minutes of
> downtime. If the plan says **"must be replaced"**, stop — that destroys the
> server and everything on it. `keep_disk` is the argument most likely to
> trigger that, so check it specifically.

Then **give the new memory to minikube**, which will not pick it up by itself:

```bash
minikube stop -p obs-lab
minikube config set -p obs-lab memory 13312     # 13 GiB, leaving the host ~3
minikube config set -p obs-lab cpus 8
minikube start -p obs-lab
kubectl get nodes -o custom-columns=NAME:.metadata.name,MEM:.status.allocatable.memory
```

Also update the default in `00-bootstrap.sh` and the `server_type` description
in `infra/variables.tf`, so the next rebuild does not silently go back to 6 GiB.

---

## 2. What we are building

```
GitHub: hello-java  ──poll──►  Jenkins (cicd ns)
                                  │  spawns ephemeral agent pod per build
                                  ▼
                        ┌─ maven container ──► mvn verify, JUnit results
                        └─ kaniko container ─► image ──► in-cluster registry
                                                             │
                                                             ▼
                                              kubectl apply ──► apps ns
                                                             │
                                  Prometheus (scenario 01) ◄──┤ /actuator/prometheus
                                  Loki (scenario 02) ◄────────┘ stdout
```

Deliberate choices, each worth understanding:

- **Ephemeral agents via the Kubernetes plugin.** Each build gets a fresh pod
  that disappears afterwards. No long-lived agent to accumulate state.
- **Kaniko, not the Docker socket.** Mounting `/var/run/docker.sock` into a
  build agent hands every Jenkinsfile root on the node. Kaniko builds an OCI
  image in userspace. This is the single most important CI security habit.
- **Configuration as Code (JCasC).** The Jenkins config lives in a values
  file, not in clicks. A Jenkins you cannot rebuild from a file is a pet.
- **Polling, not webhooks.** Jenkins is on the tailnet, so GitHub cannot reach
  it. `pollSCM('H/2 * * * *')` is the honest lab answer; note in passing that
  production would use a webhook or an outbound-only agent.

---

## 3. The Java app

Deliberately boring — the pipeline is the lesson, not the code.

Spring Boot 3, Maven, one endpoint, one test:

```
hello-java/
├── pom.xml                 spring-boot-starter-web, -actuator, -test
├── Jenkinsfile
├── Dockerfile              multi-stage: maven build -> JRE runtime
├── k8s/
│   ├── deployment.yaml     probes on /actuator/health/{liveness,readiness}
│   ├── service.yaml
│   └── servicemonitor.yaml release=kube-prom-stack, so scenario 01 scrapes it
└── src/
    ├── main/java/.../HelloController.java     GET /hello
    ├── main/resources/application.yaml        expose health,info,prometheus
    └── test/java/.../HelloControllerTest.java one @WebMvcTest
```

`micrometer-registry-prometheus` on the classpath gives `/actuator/prometheus`
for free, which means the app you deploy is immediately visible in the Grafana
you already have. That is the payoff for having built scenarios 01 and 02
first.

---

## 4. Timetable

Checkpoints are the point: if a block overruns, the fallback keeps the day
moving rather than stalling on it.

| Time | Block | Done when |
|---|---|---|
| 09:00–09:45 | **Resize.** Verify the cgroup cap, PR the Terraform change, read the plan, apply, restart minikube with the new memory, confirm allocatable | `kubectl top node` shows ~13 GiB allocatable and everything is `Running` |
| 09:45–10:45 | **The Java app.** Write it, `mvn verify` locally, push to a new GitHub repo | Green local build, repo pushed |
| 10:45–12:30 | **Jenkins.** Helm chart 5.9.63 into `cicd`, JCasC values, tailnet Service, PVC, capped resources | Jenkins UI reachable at `http://jenkins:8080` over the tailnet, admin login works |
| 12:30–13:15 | Break | |
| 13:15–14:30 | **Pipeline v1: build and test.** Jenkinsfile with checkout + `mvn -B verify` + `junit` | A build goes green and shows the test result on the job page |
| 14:30–15:45 | **Pipeline v2: the image.** Kaniko stage, in-cluster registry, tag with `${BUILD_NUMBER}-${GIT_COMMIT[0:7]}` | `crane ls` / registry API lists the pushed tag |
| 15:45–16:30 | **Pipeline v3: deploy.** `kubectl apply` into `apps`, then a smoke-test stage that curls `/hello` | The rolled-out pod serves the new build |
| 16:30–17:15 | **Wire it into the lab.** `controller.prometheus.enabled`, ServiceMonitor for the app, widen Alloy to the `cicd` and `apps` namespaces | Jenkins build metrics in Prometheus; `{namespace="cicd"}` returns lines in Loki |

**Minimum success for the day:** blocks through 14:30. A pipeline that builds
and tests a Java app on ephemeral Kubernetes agents is the core skill; images
and deployment are the natural next layer.

---

## 5. Decisions to make tomorrow

| Decision | Options | Lean |
|---|---|---|
| Where the app repo lives | new GitHub repo / subdir of `monitoring` | **New repo.** Keeps the CI trigger story honest, and a monorepo would rebuild on every observability commit |
| Registry | `minikube addons enable registry` / in-cluster `registry:2` / GHCR | **minikube registry addon** first — it is one command and the node already trusts it. Move to GHCR only if you want to practise credentials |
| Agent image | `jenkins/inbound-agent` + sidecars / a custom prebuilt image | **Sidecars in the pod template.** Slower per build, but the YAML shows exactly what each container contributes |
| Maven cache | none / PVC mounted at `/root/.m2` | **PVC.** Without it every build re-downloads the internet, and you will spend the afternoon watching it |

---

## 6. Known traps

- **The chart's controller limit is 4 GiB.** Set `controller.resources.limits.memory`
  to ~1.5Gi explicitly, or one Jenkins can eat the headroom you just paid for.
- **The agent default is 512Mi with request == limit.** That is the JNLP
  container alone. A Maven container needs its own block, and 512Mi will OOM
  mid-build with a misleading "channel closed" error in the log.
- **`installLatestPlugins: true` is the chart default,** so a rebuild can pull
  different plugin versions than today. Pin what matters once it works.
- **JCasC will not overwrite config changed in the UI** in the way you expect —
  it reapplies on restart. Treat the UI as read-only once JCasC is in place, or
  you will lose changes and not know why.
- **Kaniko needs a registry it trusts.** For an insecure in-cluster registry
  that means `--insecure` and `--skip-tls-verify` on the executor, which is
  fine in a lab and must never leave one.
- **Terraform `keep_disk`:** covered above, and worth repeating because it is
  the one irreversible step in the day.

---

## 7. Prep (largely done)

- [ ] Decide the GitHub repo name, create it empty (`obs-m23`)
- [ ] Skim the [Jenkins Kubernetes plugin pod template docs](https://plugins.jenkins.io/kubernetes/)
- [x] ~~Fix the `gpg`/pinentry issue so SSH to the host works unattended~~ —
      done 2026-09-21: `gpg-agent.conf` now uses `pinentry-gnome3`
- [x] ~~Deploy scenario 02 so the memory numbers are measured~~ — done
      2026-09-23. Measured: 4112 MiB of the 13312 cap (31%) with scenario 02
      and hello-java both running, against a projected Jenkins peak of ~3 GB.

---

## 8. Open question for after tomorrow

Jenkins builds *and* deploys here, which is CI and CD in one tool. Scenario 04
is Argo CD, which would take the deploy half away and pull it from Git instead.
Worth arriving at that scenario with an opinion about which half of this
pipeline was actually improved by that split — the honest answer is not
"all of it".
