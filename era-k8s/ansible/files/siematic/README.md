# SIEMatic on the era-k8s cluster

`upstream/` is a verbatim copy (line endings normalized) of Cliff's `ocp-runner/manifests/siematic/`
from his workspace as received on 2026-10-18 (the primary cluster's domain replaced by `openshift.example.com`, nothing else changed) (image pinned to the build of SIEMatic commit
`68ec29d`). Do not edit those files: refresh them from his repo and re-run `era siematic`.

`render.py` turns the upstream set into what this cluster can run, written by the playbook to
`/etc/era-k8s/siematic/rendered/`. The deltas, and nothing else:

1. **No OpenShift Route.** The web UI is published as a Gateway API `HTTPRoute` on the platform's
   shared gateway (`https://siematic.<domain>:8443`, the same wildcard certificate as the UI). TLS
   terminates at the gateway inside the VM and the pod serves plain HTTP; Django trusts the gateway's
   `X-Forwarded-Proto` (`DJANGO_TRUST_PROXY_PROTO_HEADER`, which SIEMatic added for this case), so the
   HTTPS redirect does not loop. The primary re-encrypts to the pod instead.
2. **No OpenShift service-serving certificates.** The indexer's TLS certificate comes from cert-manager
   (`ClusterIssuer era-ca`) into the same Secret name, `siematic-indexer-tls`; the `siematic-indexer-ca`
   ConfigMap gets the era CA under the same key, `service-ca.crt`. The web pod needs no certificate.
3. **Hostnames and ports** of the primary (`*.apps.openshift.example.com` here) become `siematic.<domain>:8443`
   and `keycloak.<domain>:8443`; the server-side OIDC endpoints (token, userinfo, JWKS) point at the
   in-cluster Keycloak Service, because `*.localtest.me` resolves to 127.0.0.1 inside a pod too.
4. **Shipper targets**: the weather agent and tool are not on this cluster, so only the reservation
   agent and tool remain; the Vault target keeps its label selector (the OpenBao chart is installed with
   `nameOverride: vault`) and gets the container name `openbao`.
5. **Vault**: the four `VaultStaticSecret`s apply unchanged against OpenBao (`era vault`), the values
   are generated inside `vault-0` the way Cliff's microshift-runner role does it; nothing is typed in.
6. **A numeric UID.** OpenShift's SCC assigns one at admission; plain Kubernetes refuses
   `runAsNonRoot: true` when the image's user is the name `appuser` ("cannot verify user is non-root"),
   so every SIEMatic pod template gets `runAsUser: 1000` (the UID `useradd` gave `appuser` in the image) and `fsGroup: 1000`, without which the indexer cannot read its 0440 TLS Secret volume.

7. **A first checkpoint per kube-logs target** (`seed-checkpoints.py`, run by the playbook). With no
   checkpoint the plugin only asks for lines newer than each poll's own start, so a target that logs
   rarely never delivers; a cursor at the container's start makes the first collection cover the whole
   log, after which the plugin advances it and survives restarts on its own. Upstream behavior, not a
   manifest change.

Everything else (Postgres, web, crawler, indexer, the two shippers, the receipt-pruning CronJob, the
RBAC in `team1` and `vault`) applies as Cliff wrote it. Two more things the primary has that this cluster
needed done explicitly: Keycloak's realm event storage is switched on, and the `siematic-events` service
account gets `view-realm` as well as `view-events` (the shipper reads the realm to check
`eventsEnabled`, and with `view-events` alone Keycloak returns a representation without that field).
