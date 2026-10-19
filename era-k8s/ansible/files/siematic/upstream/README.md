# SIEMatic on OpenShift

Manifests for the audit plane. Steps 1 to 6 are the rebuild procedure. To roll
a new SIEMatic build onto the running namespace, skip to
[Step 7](#step-7-update-to-a-new-build). To use what is already running, see
[Use the SIEMatic audit plane](../../docs/how-to-guides/use-the-siematic-audit-plane.md).

These are applied and running in the `siematic` namespace. Follow the steps in
order to rebuild the namespace from nothing.

No credential lives in this directory. All Secrets come from Vault through
the Vault Secrets Operator, the same way the weather tool's gateway credential
and Keycloak's database password already do. See
[Integrate HashiCorp Vault with Rossoctl's Kubernetes Secrets](../../docs/how-to-guides/integrate-vault-with-rossoctl-secrets.md)
for how that machinery was set up; the steps below add SIEMatic to it.

## Step 1: put the values in Vault

`VAULT_ROOT_TOKEN` comes from `~/vault-init.json` on the ocp-runner VM, which
is the only copy. Read it into the environment, do not print it, and do not
paste it anywhere it will be recorded.

Generate the application and database values and write them alongside the secrets
that are already under the `rossoctl` kv-v2 mount. The mount is named for the
product it was created for, not for a boundary; a separate mount would work
equally well and would need its own `vault secrets enable`.

```bash
oc exec -n vault vault-0 -- env VAULT_TOKEN="${VAULT_ROOT_TOKEN}" \
  vault kv put rossoctl/siematic-postgres \
    database-user=siematic \
    database-name=siematic \
    database-password="$(openssl rand -base64 24)"
```

Create two different SIEMatic write-only users in the Django `Agent` group:
`shipper-kube-logs` and `shipper-keycloak-events`. Remove both from
`Registered User`. Store their indexer credentials in distinct Vault paths.
The Kubernetes-log shipper receives only its own credential; it must not hold
the Keycloak client secret.

Generate the two passwords once and keep the shell variables until Step 6.
Each value must be used both for the Vault entry below and for its matching
Django account. Do not print either variable.

```bash
read -rsp 'Kubernetes-log shipper password: ' KUBE_SHIPPER_PASSWORD; echo
read -rsp 'Keycloak shipper password: ' KEYCLOAK_SHIPPER_PASSWORD; echo
```

The Keycloak path also needs a dedicated confidential client that has permission
to read events in `rossoctl`. Do not reuse `keycloak-initial-admin` for a
long-running collector.

```bash
oc exec -n vault vault-0 -- env VAULT_TOKEN="${VAULT_ROOT_TOKEN}" \
  vault kv put rossoctl/siematic-kube-shipper \
    INDEXER_USERNAME=shipper-kube-logs \
    INDEXER_PASSWORD="${KUBE_SHIPPER_PASSWORD}"
```

```bash
oc exec -n vault vault-0 -- env VAULT_TOKEN="${VAULT_ROOT_TOKEN}" \
  vault kv put rossoctl/siematic-keycloak-shipper \
    INDEXER_USERNAME=shipper-keycloak-events \
    INDEXER_PASSWORD="${KEYCLOAK_SHIPPER_PASSWORD}" \
    KEYCLOAK_BASE_URL="https://keycloak-keycloak.apps.openshift.example.com" \
    KEYCLOAK_CLIENT_ID=siematic-events \
    KEYCLOAK_CLIENT_SECRET="the confidential client secret" \
    KEYCLOAK_TOKEN_REALM=rossoctl
```

`KEYCLOAK_TOKEN_REALM` is required because `siematic-events` was created in
`rossoctl`. A missing key prevents the Keycloak shipper from starting.

```bash
oc exec -n vault vault-0 -- env VAULT_TOKEN="${VAULT_ROOT_TOKEN}" \
  vault kv put rossoctl/siematic-app \
    DJANGO_SECRET_KEY="$(python -c 'import secrets; print(secrets.token_urlsafe(50))')" \
    OIDC_RP_CLIENT_SECRET="the secret from the Keycloak client"
```

The key names matter. `05-vault-secrets.yaml` syncs each path into a Secret
verbatim, and the Deployments read those exact keys. `DJANGO_SECRET_KEY` and
`OIDC_RP_CLIENT_SECRET` are consumed with `envFrom`, so each key becomes an
environment variable under its own name.

## Step 2: give the namespace a policy and a role

Namespace-scoped, following the pattern used for `rossoctl-system`,
`keycloak`, and `mcp-system`. No other namespace can read these paths.

```bash
oc exec -n vault vault-0 -- env VAULT_TOKEN="${VAULT_ROOT_TOKEN}" sh -c '
cat <<POLICY | vault policy write siematic-vso -
path "rossoctl/data/siematic-postgres" { capabilities = ["read"] }
path "rossoctl/data/siematic-app"      { capabilities = ["read"] }
path "rossoctl/data/siematic-kube-shipper"     { capabilities = ["read"] }
path "rossoctl/data/siematic-keycloak-shipper" { capabilities = ["read"] }
POLICY
'
```

```bash
oc exec -n vault vault-0 -- env VAULT_TOKEN="${VAULT_ROOT_TOKEN}" \
  vault write auth/kubernetes/role/siematic-vso \
    bound_service_account_names=vault-secrets-auth \
    bound_service_account_namespaces=siematic \
    policies=siematic-vso \
    ttl=1h
```

## Step 3: Keycloak

The `siematic` client in `rossoctl` needs the Route in its valid redirect
URIs, alongside whatever local address you tested with:

```
https://siematic.apps.openshift.example.com/oidc/callback/
```

Add the same host to valid post logout redirect URIs. The role named in
`OIDC_GROUP_MAP` has to be assigned to each person who should reach SIEMatic.
Creating the role is not enough.

The Keycloak shipper needs its own confidential client, `siematic-events`,
with service accounts enabled and standard flow off. Its service account needs
`view-events` on the `realm-management` client to read
`/admin/realms/rossoctl/events`.

## Step 4: the image

Already pinned. Every `image:` field carries
`sha256:b3d85c07...`, the build of commit `68ec29d`.

Nothing is built by hand. Pushing to `main` runs `.github/workflows/image.yml`,
which builds, publishes to `ghcr.io/mcindi/siematic`, and prints the digest into
the job summary. After any later SIEMatic change, take the digest from that
summary or read it back, then repin every `image:` field:

```bash
podman image inspect ghcr.io/mcindi/siematic:main --format '{{index .RepoDigests 0}}'
```

Confirm the digest is the build you meant before applying. The image carries the
commit it came from:

```bash
podman image inspect ghcr.io/mcindi/siematic:main \
  --format '{{index .Labels "org.opencontainers.image.revision"}}'
```

A digest rather than a moving tag, because a deployment that tracks `latest`
cannot tell you afterwards what was running when an event was recorded, which
is the one question an audit plane has to answer.

The two shipper Deployments read their JSON profiles from
`25-shipper-profiles.yaml`. Keep profile names, selectors, realms, indexes, and
sources in that ConfigMap so the image remains reusable.

## Step 5: apply

Order matters. The workloads mount Secrets that VSO has not written yet, so
they will sit in `ContainerCreating` until it has.

```bash
oc apply -f 00-namespace.yaml
oc apply -f 05-vault-secrets.yaml
oc get secret siematic-postgres siematic-app siematic-kube-shipper siematic-keycloak-shipper -n siematic
```

All four Secrets appearing is the green light. If they do not, the problem is on
the Vault side, and `oc describe vaultstaticsecret -n siematic` says which
half: authentication, or the path.

```bash
oc apply -f 10-postgres.yaml
oc rollout status statefulset/siematic-postgres -n siematic
oc apply -f 20-config.yaml
oc apply -f 30-web.yaml
oc rollout status deployment/siematic-web -n siematic
```

```bash
oc apply -f 50-indexer.yaml
oc rollout status deployment/siematic-indexer -n siematic
oc apply -f 40-crawler.yaml
```

Migrations run as an init container on the web Deployment rather than as a
separate Job. It is idempotent and removes the ordering race. The default
groups that authorization depends on, `Registered User` and `Agent`, are
created by `project/signals.py` on `post_migrate` of the `crawlers` app, so
they exist as soon as that init container has run once.

## Step 6: after the first rollout

Create a local break-glass superuser. Use it to create the two write-only
shipper identities and to verify the dashboards, because browser sign-in
depends on Step 3 having been done. Keep the account afterwards: it is the way
back in when Keycloak itself is the thing that is broken.

```bash
oc rsh deployment/siematic-web -n siematic python manage.py createsuperuser
```

Before applying either shipper Deployment, create the two accounts with the
passwords retained from Step 1. Add each to `Agent` and remove it from
`Registered User`; `Agent` grants the indexer write permission but not event
read permission. Use the local Django admin or shell to do this, then verify
the memberships before proceeding. The shippers reject missing or unauthorized
credentials permanently, by design.

```bash
oc rsh deployment/siematic-web -n siematic python manage.py check_shipper_users
```

Then seed the bundled saved searches and dashboards with that local account:

```bash
oc rsh deployment/siematic-web -n siematic python manage.py seed_default_content --owner BREAK_GLASS_USERNAME
```

```bash
oc apply -f 25-shipper-profiles.yaml
oc apply -f 60-kube-logs.yaml
oc apply -f 70-keycloak-events.yaml
oc apply -f 80-maintenance.yaml
```

A new audited workload needs an entry in `25-shipper-profiles.yaml` before it
produces any events.

Verify `siematic-kube-logs` has `get` and `list` on `pods` and `pods/log` in
`team1` and `vault`, plus `get` on `deployments` in `team1` only (needed to
resolve a `deployment: name` target to its current pod; the `vault` target
resolves through a pod label selector instead). The Keycloak shipper has no
Kubernetes log RBAC. The
two agent Deployments run with `Recreate` to preserve one owner per cursor.

## Step 7: update to a new build

The routine for a SIEMatic change that has been pushed to `main`. It replaces
the image and nothing else. Steps 1 to 3 and 6 are not repeated.

`scripts/rollout-siematic.sh` does all of it. Run it in the VM once CI is
green, with the SIEMatic commit that was pushed:

```bash
bash /vagrant/scripts/rollout-siematic.sh <commit>
```

It resolves the index digest from the registry by the `sha-` tag, confirms
the image's revision label is that commit, repins the seven image fields and
this README, applies non-shippers then shippers, waits 90 seconds, and checks
restarts, shipper logs, and fresh events per index. Add `--check` to resolve
and print without changing anything. It edits the Windows working tree
through `/vagrant` and does not run git, so commit on Windows afterwards with
the command it prints. The manual steps below are what it does.

1. Wait for `.github/workflows/image.yml` in the SIEMatic repo to go green
   and take the digest from the job summary, the line that reads
   `digest: sha256:...`. That is the OCI image index digest, the one the
   attestation covers. Do not take it from `podman image inspect`: podman
   reports the amd64 manifest digest, which differs from the index digest and
   does not match the summary. To confirm the summary digest is the commit
   you pushed, check the revision label in the VM:

   ```bash
   podman pull -q ghcr.io/mcindi/siematic@sha256:DIGEST >/dev/null && podman image inspect ghcr.io/mcindi/siematic@sha256:DIGEST --format '{{index .Labels "org.opencontainers.image.revision"}}'
   ```

2. Repin every `image:` field in this directory. There are seven: two in
   `30-web.yaml` (the `migrate` init container and `web`), and one each in
   `40-crawler.yaml`, `50-indexer.yaml`, `60-kube-logs.yaml`,
   `70-keycloak-events.yaml`, and `80-maintenance.yaml`. Update the digest
   and commit named in Step 4 at the same time. From the ocp-runner
   directory:

   ```bash
   sed -i 's/sha256:OLD_DIGEST/sha256:NEW_DIGEST/g' manifests/siematic/*.yaml manifests/siematic/README.md && grep -c NEW_DIGEST manifests/siematic/*.yaml
   ```

   The count is 2 for the web manifest and 1 for each of the other five.
   Commit before applying, so the repo records what the cluster runs.

3. Apply in the VM. The VM's `/vagrant` mirrors the Windows working tree, so
   whatever is checked out is what gets applied. Non-shippers first, so the
   indexer is up before the shippers reconnect to it:

   ```bash
   cd /vagrant/manifests/siematic && oc apply -f 30-web.yaml -f 40-crawler.yaml -f 50-indexer.yaml -f 80-maintenance.yaml && oc rollout status deployment/siematic-indexer -n siematic && oc apply -f 60-kube-logs.yaml -f 70-keycloak-events.yaml && oc rollout status deployment/siematic-kube-logs -n siematic && oc rollout status deployment/siematic-keycloak-events -n siematic
   ```

   Migrations need nothing extra: the web init container runs them before
   the rest of the rollout. The shippers use `Recreate` and resume from the
   indexer's checkpoints, so the gap during their restart loses no events.

4. Verify. Every pod Running with zero restarts, and fresh events landing in
   each evidence index. `keycloak` can be quiet if nobody has signed in;
   check its latest timestamp is unchanged rather than missing.

   ```bash
   oc get pods -n siematic && oc exec -n siematic siematic-postgres-0 -- psql -U siematic -d siematic -Atc "select index, count(*) filter (where created > now() - interval '10 minutes') as recent, to_char(max(created) at time zone 'UTC','HH24:MI:SS') as latest_utc from events_event where index in ('authbridge','vault','keycloak','agents') group by index order by index"
   ```

   Then confirm the shipper logs have no tracebacks:

   ```bash
   oc logs deploy/siematic-kube-logs -n siematic --since=15m | grep -ciE 'error|traceback|exception'; oc logs deploy/siematic-keycloak-events -n siematic --since=15m | grep -ciE 'error|traceback|exception'
   ```

5. Roll back one Deployment if a build misbehaves. This returns it to the
   previous digest without touching the others. Repin the manifest afterwards
   so the repo matches again.

   ```bash
   oc rollout undo deployment/siematic-kube-logs -n siematic
   ```

Two cases change the order. If the SIEMatic change alters the profile format
or the loader's required environment variables, update
`25-shipper-profiles.yaml` or the Vault path first and apply the ConfigMap
before the shipper Deployments. The shippers fail closed at startup on a
profile they cannot validate, and the error names the field. If the change
adds a Django group or permission the shipper accounts depend on, run
`check_shipper_users` from Step 6 after the web rollout and before the
shippers.
