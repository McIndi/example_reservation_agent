#!/usr/bin/env python3
"""Render Cliff's SIEMatic OpenShift manifests for the era-k8s cluster (see README.md next to this file).

usage: render.py UPSTREAM_DIR OUT_DIR DOMAIN PORT KEYCLOAK_PUBLIC_URL KEYCLOAK_INTERNAL_URL KEEP_DEPLOYMENTS

KEEP_DEPLOYMENTS is a comma-separated list of team1 Deployments whose authbridge-proxy logs are shipped.
"""
import json
import pathlib
import sys

import yaml

src, dst, domain, port, kc_public, kc_internal, keep = sys.argv[1:8]
src, dst = pathlib.Path(src), pathlib.Path(dst)
keep = {x for x in keep.split(",") if x}
host = f"siematic.{domain}"
public = f"https://{host}:{port}"
dst.mkdir(parents=True, exist_ok=True)


def strip_serving_cert(deployment):
    spec = deployment["spec"]["template"]["spec"]
    spec["volumes"] = [v for v in spec.get("volumes", []) if v["name"] != "serving-cert"] or None
    if spec["volumes"] is None:
        del spec["volumes"]
    for c in spec["containers"]:
        c["volumeMounts"] = [m for m in c.get("volumeMounts", []) if m["name"] != "serving-cert"] or None
        if c["volumeMounts"] is None:
            c.pop("volumeMounts", None)
        for probe in ("startupProbe", "livenessProbe", "readinessProbe"):
            if probe in c and "httpGet" in c[probe]:
                c[probe]["httpGet"]["scheme"] = "HTTP"
        for p in c.get("ports", []):
            if p.get("name") == "https":
                p["name"] = "http"


def edit_app_config(data):
    old_issuer = data.get("OIDC_ISSUER", "")
    realm = old_issuer.rsplit("/realms/", 1)[-1] or "rossoctl"
    hosts = [h for h in data["DJANGO_ALLOWED_HOSTS"].split(",") if not h.startswith("siematic.apps.")]
    data["DJANGO_ALLOWED_HOSTS"] = ",".join([host] + hosts)
    data["DJANGO_CSRF_TRUSTED_ORIGINS"] = public
    data["OIDC_ISSUER"] = f"{kc_public}/realms/{realm}"
    for key, path in (("OIDC_OP_TOKEN_ENDPOINT", "token"), ("OIDC_OP_USER_ENDPOINT", "userinfo"),
                      ("OIDC_OP_JWKS_ENDPOINT", "certs")):
        data[key] = f"{kc_internal}/realms/{realm}/protocol/openid-connect/{path}"
    data["CHERRYPY_SSL"] = "False"
    data.pop("CHERRYPY_SSL_CERT", None)
    data.pop("CHERRYPY_SSL_KEY", None)


def edit_shipper_profiles(data):
    prof = json.loads(data["kube-logs.json"])
    targets = []
    for t in prof["targets"]:
        if t.get("deployment") and t["deployment"] not in keep:
            continue
        if t.get("vault_audit"):
            t["container"] = "openbao"
        targets.append(t)
    prof["targets"] = targets
    data["kube-logs.json"] = json.dumps(prof, indent=2) + "\n"


SIEMATIC_UID = 1000  # `useradd -m appuser` in the SIEMatic Dockerfile (Debian base): first regular UID


def numeric_user(doc):
    """OpenShift's SCC gives the pod a numeric UID; plain Kubernetes refuses runAsNonRoot with the
    image's symbolic user ("image has non-numeric user (appuser), cannot verify user is non-root"), and
    the SCC's fsGroup is what lets the pod read a 0440 Secret volume."""
    tmpl = doc["spec"].get("jobTemplate", {}).get("spec", {}).get("template") if doc["kind"] == "CronJob" \
        else doc["spec"].get("template")
    if not tmpl:
        return
    spec = tmpl["spec"]
    images = [c.get("image", "") for c in spec.get("containers", []) + spec.get("initContainers", [])]
    if any("mcindi/siematic" in i for i in images):
        sc = spec.setdefault("securityContext", {})
        sc["runAsUser"] = SIEMATIC_UID
        sc["fsGroup"] = SIEMATIC_UID  # secret volumes are mounted 0440 root:root otherwise (indexer TLS)


httproute = {
    "apiVersion": "gateway.networking.k8s.io/v1",
    "kind": "HTTPRoute",
    "metadata": {"name": "siematic", "namespace": "siematic", "labels": {"app": "siematic-web"}},
    "spec": {
        "parentRefs": [{"name": "http", "namespace": "rossoctl-system", "sectionName": "https"}],
        "hostnames": [host],
        "rules": [{"backendRefs": [{"name": "siematic-web", "port": 8000}]}],
    },
}

for f in sorted(src.glob("*.yaml")):
    out = []
    for d in yaml.safe_load_all(f.read_text()):
        if not d:
            continue
        kind, name = d.get("kind"), d["metadata"]["name"]
        if kind == "Route":
            continue
        if kind == "ConfigMap" and name == "siematic-indexer-ca":
            continue  # the playbook creates it with the era CA under service-ca.crt
        if kind == "Service":
            d["metadata"].pop("annotations", None)
            if name == "siematic-web":
                for p in d["spec"]["ports"]:
                    if p.get("name") == "https":
                        p["name"] = "http"
        if kind == "ConfigMap" and name == "siematic-app":
            edit_app_config(d["data"])
        if kind == "ConfigMap" and name == "siematic-shipper-profiles":
            edit_shipper_profiles(d["data"])
        if kind == "Deployment" and name == "siematic-web":
            strip_serving_cert(d)
        if kind in ("Deployment", "CronJob", "StatefulSet"):
            numeric_user(d)
        out.append(d)
    if f.name == "30-web.yaml":
        out.append(httproute)
    (dst / f.name).write_text(yaml.safe_dump_all(out, sort_keys=False, default_flow_style=False))
    print(f"rendered {f.name}: {len(out)} object(s)")
