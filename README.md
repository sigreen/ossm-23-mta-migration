# OSSM 2.x → 3.x Migration Demo with MTA 8.3.3

A live demo showing how to use **Migration Toolkit for Applications (MTA) 8.3.3** to analyze, plan, and execute a migration from **OpenShift Service Mesh 2.x** (Maistra) to **OpenShift Service Mesh 3.x** (Sail Operator / upstream Istio).

## Demo Materials

| Document | Description |
|---|---|
| [Slide Outline](slides-outline.md) | 14-slide deck covering architecture differences, MTA overview, demo flow, before/after YAML, and validation |
| [Demo Script](demo-script.md) | Full scene-by-scene script with narration cues, CLI commands, timing, and contingency notes |

---

## Prerequisites

- OCP 4.18+ cluster with `cluster-admin`
- `oc` CLI logged in
- MTA 8.3.3 installed in the `mta` namespace (via OperatorHub)
- Gitea installed in the `gitea` namespace (used as the MTA source repo)

> **MTA setup note:** If MTA is managed by ArgoCD, suspend auto-sync before changing the operator channel.
> See [Demo Script Scene 2](demo-script.md#scene-2) for details.

---

## Installation

### Step 1 — Install OSSM 2.x operators

```bash
# Kiali, Jaeger, and Service Mesh operators (all go into openshift-operators)
oc apply -f - <<'EOF'
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: kiali-ossm
  namespace: openshift-operators
spec:
  channel: stable
  name: kiali-ossm
  source: redhat-operators
  sourceNamespace: openshift-marketplace
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: jaeger-product
  namespace: openshift-operators
spec:
  channel: stable
  name: jaeger-product
  source: redhat-operators
  sourceNamespace: openshift-marketplace
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: servicemeshoperator
  namespace: openshift-operators
spec:
  channel: stable
  name: servicemeshoperator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

# Wait for all three to reach Succeeded
until oc get csv -n openshift-operators | grep -q 'kiali-operator.*Succeeded' && \
      oc get csv -n openshift-operators | grep -q 'jaeger-operator.*Succeeded' && \
      oc get csv -n openshift-operators | grep -q 'servicemeshoperator.*Succeeded'; do
  sleep 15
done
echo "OSSM 2.x operators ready"
```

### Step 2 — Deploy the OSSM 2.x control plane

```bash
oc apply -f setup/ossm2/01-control-plane.yaml

# Wait for SMCP to be fully ready (~2-3 minutes)
until oc get smcp basic -n istio-system \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' | grep -q True; do
  sleep 15
done
echo "SMCP ready"
```

### Step 3 — Deploy the demo applications

```bash
oc apply -f setup/apps/bookinfo.yaml
oc apply -f setup/apps/custom-app.yaml
```

### Step 4 — Grant anyuid SCC to bookinfo service accounts

Required because the bookinfo images run as `UID 1000`, which falls outside the OCP namespace UID range.

```bash
for sa in bookinfo-details bookinfo-ratings bookinfo-reviews bookinfo-productpage; do
  oc adm policy add-scc-to-user anyuid -z $sa -n bookinfo
done
oc adm policy add-scc-to-user anyuid -z httpbin -n custom-app
```

### Step 5 — Restart pods for sidecar injection

Wait for SMMR to enroll the namespaces, then restart pods so the Istio proxy is injected.

```bash
until oc get smmr default -n istio-system \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' | grep -q True; do
  sleep 10
done

oc rollout restart deployment -n bookinfo
oc rollout restart deployment -n custom-app

# Wait for 2/2 (app + istio-proxy)
until oc get pods -n bookinfo --no-headers | awk '{print $2}' | grep -q '2/2'; do
  sleep 8
done
echo "Sidecars injected"
```

### Step 6 — Set up MTA custom rules and application

The OSSM 2→3 migration rules are in `setup/mta-rules/ossm-migration-rules.yaml`. Upload them to MTA and configure the analysis target:

```bash
MTA_HOST=$(oc get route mta -n mta -o jsonpath='{.spec.host}')

# Upload rules file
FILE_ID=$(curl -sk -X POST "https://${MTA_HOST}/hub/files/ossm-migration-rules.yaml" \
  -H "Content-Type: application/octet-stream" \
  --data-binary @setup/mta-rules/ossm-migration-rules.yaml | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")

# Create ruleset
RULESET_ID=$(curl -sk -X POST "https://${MTA_HOST}/hub/rulesets" \
  -H "Content-Type: application/json" \
  -d "{\"name\":\"OSSM 2 to 3 Migration\",\"description\":\"Rules for migrating OSSM 2.x to OSSM 3.x\",\"rules\":[{\"file\":{\"id\":${FILE_ID}}}]}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")

# Get a migration image ID (reuse Quarkus icon)
IMAGE_ID=$(curl -sk "https://${MTA_HOST}/hub/targets" | python3 -c "
import sys,json; targets=json.load(sys.stdin)
for t in targets:
    if 'migration' in t.get('image',{}).get('name',''):
        print(t['image']['id']); break")

# Create custom target
curl -sk -X POST "https://${MTA_HOST}/hub/targets" \
  -H "Content-Type: application/json" \
  -d "{\"name\":\"OpenShift Service Mesh 3\",\"description\":\"Migrate from OSSM 2.x to OSSM 3.x (Sail Operator)\",\"provider\":\"Kubernetes\",\"choice\":false,\"labels\":[{\"name\":\"OSSM 3\",\"label\":\"konveyor.io/target=ossm3\"}],\"image\":{\"id\":${IMAGE_ID}}}" > /dev/null

# Push OSSM config to Gitea for MTA to analyze
GITEA_HOST=$(oc get route gitea -n gitea -o jsonpath='{.spec.host}')
# (create repo in Gitea UI or via API, then push the YAML exports)
```

### Step 7 — Export OSSM config and push to Gitea

```bash
mkdir -p /tmp/ossm-export
for resource in servicemeshcontrolplane servicemeshmemberroll servicemeshmember \
                virtualservice destinationrule gateway \
                peerauthentication authorizationpolicy; do
  oc get $resource -A -o yaml > /tmp/ossm-export/${resource}.yaml 2>/dev/null
done
# Push these files to Gitea (gitea-admin/ossm-config repo)
# Then create the MTA application pointing to the Gitea repo URL
```

### Verification

```bash
# OSSM 2.x running
oc get smcp -n istio-system              # Expected: 8/8 ComponentsReady

# Apps with sidecars
oc get pods -n bookinfo                  # Expected: all 2/2

# Bookinfo accessible
curl -so /dev/null -w "%{http_code}" \
  http://istio-ingressgateway-istio-system.apps.<cluster-domain>/productpage
# Expected: 200
```

---

## Demo Flow Summary

| Scene | What You Show | Time |
|---|---|---|
| Slides 1–7 | Architecture context, OSSM 2 vs 3 differences, MTA overview | 10 min |
| Scene 1 | OSSM 2.x running — SMCP, SMMR, pods with sidecars, Kiali topology | 5 min |
| Scene 2 | MTA application + custom OSSM 3 target + existing analysis | 8 min |
| Scene 3 | Walk the report — 6 mandatory, 2 optional, 2 informational findings | 8 min |
| Scene 4 | Apply migration — install OSSM 3, remove SMCP, deploy Kiali + gateway | 10 min |
| Scene 5 | Validate — control plane, proxy version, mTLS, productpage 200 | 5 min |
| Q&A | | 10 min |

---

## Repository Structure

```
.
├── README.md
├── slides-outline.md          # 14-slide deck outline
├── demo-script.md             # Full scene-by-scene demo script
└── setup/
    ├── 00-setup-order.sh      # End-to-end setup script
    ├── apps/
    │   ├── bookinfo.yaml      # Bookinfo sample app + mesh resources
    │   └── custom-app.yaml    # httpbin + PeerAuthentication + AuthorizationPolicy
    ├── mta-rules/
    │   └── ossm-migration-rules.yaml   # 10 custom Kantra rules for OSSM 2→3
    ├── ossm2/
    │   └── 01-control-plane.yaml       # SMCP + SMMR
    └── ossm3/
        ├── 01-ossm3-operator.yaml      # servicemeshoperator3 subscription
        ├── 02-control-plane.yaml       # Istio + IstioCNI CRs (Sail Operator)
        └── 03-ingressgateway.yaml      # Standalone ingress gateway Deployment + Route
```

---

## Key Talking Points

- **MTA extensibility** — no built-in OSSM target ships in MTA 8.3.3; the custom Kantra rules in this repo demonstrate how customers add their own platform migration rules
- **10 findings, 6 mandatory** — without MTA this is a full-day manual YAML audit; MTA does it in minutes with a prioritized action plan and story-point effort estimates  
- **OSSM 3 tracks upstream Istio** — no Maistra fork, faster releases, Gateway API first class
- **Namespace enrollment by label** replaces SMMR — simpler, GitOps-friendly
- **Kiali and the ingress gateway are decoupled** in OSSM 3 — upgradeable independently, owned separately per team
- **`IstioRevision` canary** = zero-downtime production migrations (mention if asked)

---

## Environment Reference (this demo)

| Component | Version |
|---|---|
| OCP | 4.18.56 |
| OSSM 2.x (source) | 2.6.17 |
| OSSM 3.x (target) | 3.3.9 / Istio 1.28.10 |
| MTA | 8.3.3 |
| Kiali | 2.33.1 |
