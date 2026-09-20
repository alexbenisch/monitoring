---
title: "obs-lab infrastructure"
author: "Alex Benisch"
date: 2026-09-20
geometry: "margin=1.5cm"
papersize: a4
---

# Infrastructure

Terraform for the lab host and its DNS, driven entirely from GitHub Actions.
Nothing here is applied from a laptop.

## What it creates

| Resource | Detail |
|---|---|
| `hcloud_server.lab` | `cpx32` — 4 vCPU / 8 GB / 160 GB, in `nbg1`, Ubuntu 24.04 |
| `hcloud_ssh_key.admin` | your public key, uploaded to the project |
| `hcloud_firewall.lab` | inbound 22 / 80 / 443 / ICMP — **and nothing else** |
| `cloudflare_dns_record.lab` | `app.kubetest.uk`, `monitoring.kubetest.uk` → A record |
| `cloudflare_dns_record.lab_v6` | the same two names → AAAA record |

cloud-init installs Docker, kubectl, helm and minikube, raises the inotify and
`vm.max_map_count` limits Prometheus and minikube need, and drops a marker file
at `/var/lib/cloud/obs-lab-ready` when it has finished.

Grafana (3000), Prometheus (9090) and Alertmanager (9093) are **not** open on
the firewall. Reach them the way scenario 01 says to:

```bash
ssh -L 3000:localhost:3000 -L 9090:localhost:9090 -L 9093:localhost:9093 lab@<ip>
```

## One-time setup

**1. Create the S3 credentials.** Hetzner Console → Object Storage → generate
an access key pair. Terraform cannot create the bucket that holds its own
state, and `hcloud`'s CLI does not manage Object Storage, so the bucket itself
is made by the **bootstrap-state** workflow below.

**2. Secrets** — already set, verify with `gh secret list`:

| Secret | What |
|---|---|
| `HCLOUD_TOKEN` | Hetzner Cloud API token, Read & Write |
| `CLOUDFLARE_API_TOKEN` | scoped: `Zone:Read` + `DNS:Edit` on `kubetest.uk` |
| `HCLOUD_S3_ACCESS_KEY` | Object Storage access key |
| `HCLOUD_S3_SECRET_KEY` | Object Storage secret key |

**3. Variables** — not secrets, so these are repo *variables*. Set all three:

```bash
gh variable set TF_STATE_BUCKET   --body "tfstate-obs-lab"
gh variable set TF_STATE_ENDPOINT --body "https://nbg1.your-objectstorage.com"
gh variable set SSH_PUBLIC_KEY    < ~/.ssh/id_ed25519.pub
```

The endpoint region must match where you created the bucket — `nbg1`, `fsn1`
or `hel1`. The workflow fails early and names anything missing.

`gh variable set SSH_PUBLIC_KEY < key.pub` stores the file's **trailing
newline** as part of the value. Terraform trims it (`local.ssh_public_key`),
because Hetzner is picky about trailing whitespace on a key and it would
otherwise appear as a permanent diff on every plan. A GPG authentication
subkey works fine — export it in OpenSSH form first:

```bash
gpg --export-ssh-key 0xYOURKEYID > ~/.ssh/gpg-auth.pub
```

Both variables are sanity-checked before anything runs: the key must be a real
OpenSSH public key (a private key, a `.pem` or raw PGP armor is rejected with a
useful message), and `HCLOUD_TOKEN` must be exactly 64 characters, which is the
usual symptom of a truncated paste.

**4. Create the state bucket.** Actions → **bootstrap-state** → Run workflow,
typing the bucket name to confirm. It creates the bucket if missing, turns on
versioning (state is the one file where an overwrite is fatal), and fails if
the bucket answers anonymous reads.

Note `workflow_dispatch` only offers workflows that exist on the **default
branch** — a workflow added on a feature branch will not appear in the Actions
UI until it is merged.

## Running it

| Want | Do |
|---|---|
| See a plan | open a PR touching `infra/**` — the plan is posted as a comment |
| Create/update | Actions → **terraform** → Run workflow → `apply` |
| Tear down | Actions → **terraform** → Run workflow → `destroy`, and type `destroy` in the confirm box |
| Ask Hetzner something | Actions → **hcloud** → Run workflow → `status`, `server-types`, … |

`apply` applies the **saved plan** from the same run, so what executes is
exactly what was printed — not a fresh plan that drifted in between.

Runs are serialised by a `concurrency` group. The backend also sets
`use_lockfile = true`; if Hetzner's Object Storage rejects the conditional
write with a 501, delete that line in `backend.tf` — the concurrency group is
the guard that actually matters here.

## Two things that will bite you

**The Cloudflare provider is v5, and v5 renamed things.** `cloudflare_record`
is now `cloudflare_dns_record`, its `value` is now `content`, and
`data "cloudflare_zone"` takes a `zone_id` — it can no longer look a zone up by
name. Going from a domain to an id needs the plural `data "cloudflare_zones"`,
which is what `dns.tf` does. Most v4 examples you find online will not work.

**Running Terraform locally on Arch fails confusingly.** The Arch package
installs a filesystem provider mirror at `/usr/share/terraform/plugins`
containing `hetznercloud/hcloud` v1.47.0. Terraform treats an implied local
mirror as authoritative for that provider and stops consulting the registry, so
any modern constraint fails with:

```
Could not retrieve the list of available versions for provider
hetznercloud/hcloud: no available releases match the given constraints ~> 1.69
```

It has nothing to do with the registry or the constraint. Force direct
installation:

```bash
cat > /tmp/direct.tfrc <<'EOF'
provider_installation {
  direct {}
}
EOF
export TF_CLI_CONFIG_FILE=/tmp/direct.tfrc
terraform -chdir=infra init -backend=false
```

CI is unaffected — GitHub runners have no such directory.

## Cost

Hetzner's prices moved during 2026, so rather than trusting a number written
here, ask the API for the current one:

```bash
hcloud server-type describe cpx32
```

Object Storage bills a monthly minimum whatever the state file's size, so
destroying the server stops the server cost and not the bucket cost.
