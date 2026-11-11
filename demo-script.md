# Demo Script: OSSM 2.x → 3.x Migration with MTA 8.3.3
**Environment:** OCP 4.18.56 | MTA 8.3.3 | OSSM 2.6.17 (source) | OSSM 3.3.9 / Sail Operator (target)

---

## Quick-Reference URLs

| Component | URL |
|---|---|
| MTA Console | https://mta-mta.apps.cluster-pt77w.dyn.redhatworkshops.io |
| Kiali | https://kiali-istio-system.apps.cluster-pt77w.dyn.redhatworkshops.io |
| Jaeger | https://jaeger-istio-system.apps.cluster-pt77w.dyn.redhatworkshops.io |
| Bookinfo app | http://istio-ingressgateway-istio-system.apps.cluster-pt77w.dyn.redhatworkshops.io/productpage |
| Gitea OSSM config | https://gitea.apps.cluster-pt77w.dyn.redhatworkshops.io/gitea-admin/ossm-config |

---

## Pre-Demo Checklist (run before audience arrives)

```bash
# 1. Confirm OSSM 2.x is healthy
oc get smcp -n istio-system
# Expected: basic   8/8   ComponentsReady   2.6.17

# 2. Confirm apps have sidecars (2/2)
oc get pods -n bookinfo --no-headers | awk '{print $1, $2}'
oc get pods -n custom-app --no-headers | awk '{print $1, $2}'
# All should show 2/2

# 3. Confirm MTA is up
oc get pods -n mta --no-headers | grep -v Completed
# Expected: mta-hub, mta-operator, mta-ui all Running

# 4. Quick HTTP smoke test
curl -so /dev/null -w "%{http_code}" \
  http://istio-ingressgateway-istio-system.apps.cluster-pt77w.dyn.redhatworkshops.io/productpage
# Expected: 200

# 5. Open these browser tabs BEFORE you start:
#    Tab 1: OCP Console → istio-system namespace
#    Tab 2: MTA Console (URL above)
#    Tab 3: Kiali (URL above)
#    Tab 4: Bookinfo productpage (URL above)
#    Tab 5: Gitea ossm-config repo (URL above)
```

---

## Scene 1 — The Starting Point: OSSM 2.x Running [~5 min]

> "We're starting with a healthy OSSM 2.6 deployment on OCP 4.18. This is a typical enterprise
> setup — a Bookinfo sample app and a custom httpbin service, both enrolled in the mesh via a
> ServiceMeshMemberRoll."

```bash
# Show control plane — point out Maistra API, ComponentsReady, version
oc get smcp -n istio-system -o wide
```

```bash
# Show namespace enrollment — point out spec.members: Maistra-specific, no upstream equivalent
oc get smmr -n istio-system -o yaml | grep -A5 'spec:\|members:'
```

```bash
# Show custom-app opted itself in with ServiceMeshMember
oc get servicemeshmember default -n custom-app -o yaml | head -20
```

```bash
# Show pods with sidecars (2/2 = app + istio-proxy)
oc get pods -n bookinfo
oc get pods -n custom-app
```

**Switch to Kiali (Tab 3):**
> "In Kiali we see the mesh topology — bookinfo services connected, mTLS padlocks on all edges."

```bash
# Show what OSSM 2.x config looks like — the proprietary Maistra spec
oc get smcp basic -n istio-system -o yaml | grep -A8 'security:\|tracing:\|addons:\|gateways:'
```

**Transition:**
> "Migrating to OSSM 3 means every one of these Maistra-specific resources — the SMCP, SMMR,
> ServiceMeshMember — needs to be replaced. Rather than hunting through every YAML manually,
> we're going to let MTA map the work for us."

---

## Scene 2 — MTA Analysis: What Needs to Change [~8 min]

**Switch to MTA Console (Tab 2)**

> "MTA 8.3.3 is running on the same OCP cluster, deployed from OperatorHub. I've already set up
> an application called 'ossm-mesh-config' that points to a Gitea repository containing all the
> mesh configuration we just looked at — the SMCP, SMMR, VirtualServices, DestinationRules,
> PeerAuthentications, everything."

### 2a — Walk through the application setup

1. Click **Applications** in the left nav
2. Click **ossm-mesh-config** to open it
3. Click the **Source** tab → show the Gitea URL (`gitea-admin/ossm-config`)
4. **Switch to Gitea tab** to show the actual YAML files in the repo
5. **Switch back to MTA**

> "One important thing to highlight: MTA 8.3.3 doesn't ship with a built-in OSSM migration
> target out of the box — the standard targets are Java, .NET, cloud-readiness. So we created
> a custom target using MTA's extensible Kantra rule format. Let me show you."

6. Click **Administration** → **Custom migration targets**
7. Show the **OpenShift Service Mesh 3** target
8. Click on it → show the custom ruleset "OSSM 2 to 3 Migration"

> "These are YAML-based Kantra rules that detect every Maistra-specific API and produce
> categorized findings with remediation guidance. This is exactly how customers would add
> their own platform migration rules."

### 2b — Show the existing analysis (already ran)

1. Click **Applications** → **ossm-mesh-config** → **Reports** tab
2. Click on the analysis report

> "The analysis already ran — it took about 3 minutes to clone the repo and scan the YAMLs.
> Total effort estimate: **21 story points** across 8 findings."

**[Optional live re-run — only if you have 4 min of buffer]**
```bash
# Reset and re-run the analysis fresh via API if needed
# (The UI 'Analyze' button achieves the same thing)
```

---

## Scene 3 — Reviewing MTA Findings [~8 min]

**In the MTA report view**

> "Let's walk through what MTA found, starting with the blockers."

### Mandatory findings (4 findings — must fix before migration):

**Finding: ossm-smcp-mandatory-001 — ServiceMeshControlPlane**
> "24 matches across the config files — this is the big one. The SMCP wraps all Istio config
> in a Maistra-proprietary API. MTA tells us: replace it with an `Istio` CR via the OSSM 3
> Sail Operator. It also flags that the CNI config must become a separate `IstioCNI` resource.
> 5 story points estimated for the config mapping."

**Finding: ossm-smmr-mandatory-002 — ServiceMeshMemberRoll**
> "The SMMR simply doesn't exist in OSSM 3. MTA's remediation: label namespaces with
> `istio-injection=enabled`. One line of `oc label` per namespace instead of maintaining
> a central enrollment list."

**Finding: ossm-servicemeshmember-mandatory-003 — ServiceMeshMember**
> "Same pattern — this Maistra CRD is gone. The namespace label replaces it."

**Finding: ossm-smcp-mtls-mandatory-005 — SMCP mTLS config**
> "The `security.dataPlane.mtls: true` SMCP field has no equivalent in Sail Operator. MTA
> gives us the exact replacement: a mesh-wide `PeerAuthentication` in `istio-system`."

### Optional findings (2 findings — post-migration roadmap):

**Finding: ossm-smcp-jaeger-optional-006 — Bundled Jaeger**
> "OSSM 3 doesn't bundle Jaeger. MTA flags this as optional — your existing Jaeger instance
> keeps working as an external service, but long-term Red Hat Tempo + OpenTelemetry is the
> aligned path."

**Finding: ossm-gateway-api-optional-007 — Classic Gateway resources**
> "Classic `Gateway` and `VirtualService` still work in OSSM 3, but MTA recommends starting
> the journey to Kubernetes Gateway API. That's on the roadmap, not a blocker."

### Potential/informational findings (2 findings — no action needed):

**Findings: PeerAuthentication + AuthorizationPolicy**
> "Good news — these are upstream Istio APIs and are fully compatible with OSSM 3. MTA just
> flags them so you know they exist. No YAML changes required."

**Show the effort summary:**
> "In total: 21 story points, 4 mandatory blockers. That's the entire migration checklist.
> Without MTA we'd spend a day or two auditing YAML files to find this. MTA does it in
> minutes and gives us a prioritized action plan."

---

## Scene 4 — Applying the Migration [~10 min]

**Switch to terminal**

> "Now we act. We'll install OSSM 3, remove the SMCP, apply the equivalent config, and
> migrate namespace enrollment."

### 4a — Install the OSSM 3 operator (Red Hat servicemeshoperator3)

```bash
# Install the OSSM 3 operator (Sail Operator based, Red Hat supported)
cat <<'EOF' | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: servicemeshoperator3
  namespace: openshift-operators
spec:
  channel: stable
  installPlanApproval: Automatic
  name: servicemeshoperator3
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

# Watch for the CSV to reach Succeeded
oc get csv -n openshift-operators -w | grep servicemeshoperator3
```
_Point out: same OperatorHub, Red Hat supported, channel stable = v3.3.9_

### 4b — Remove the SMCP (shuts down OSSM 2.x control plane)

> "Before creating the OSSM 3 control plane, we remove the SMCP. This gracefully shuts down
> the OSSM 2.x istiod and gateway pods — the app pods keep running, they just lose mesh
> management temporarily."

```bash
# Delete SMCP — removes istiod, ingressgateway, Kiali, Jaeger from istio-system
oc delete smcp basic -n istio-system

# Watch the istio-system pods wind down
oc get pods -n istio-system -w
```

### 4c — Create IstioCNI CR

> "In OSSM 2.x, the CNI configuration was embedded inside the SMCP. In OSSM 3, it's a
> dedicated resource in its own namespace — a cleaner separation of concerns."

```bash
# Create istio-cni namespace
oc create namespace istio-cni 2>/dev/null || true

# Apply IstioCNI — replaces the CNI section of the old SMCP
oc apply -f setup/ossm3/02-control-plane.yaml

# Wait for IstioCNI to be ready
until oc get istiocni default -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' \
  2>/dev/null | grep -q True; do sleep 5; done
echo "IstioCNI ready"
oc get istiocni
```

### 4d — Create the Istio CR (replaces SMCP)

> "This is the MTA-guided equivalent of our SMCP, using the upstream Istio API. What took 80
> lines of Maistra-specific YAML is now a clean, upstream-compatible Istio CR."

```bash
oc get istio -n istio-system 2>/dev/null || echo "Istio CR not yet created"

# (IstioCNI and Istio were both in the same file — it's already applied)
# Wait for Istio control plane to be ready
until oc get istio default -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' \
  2>/dev/null | grep -q True; do
  echo "Waiting for Istio control plane..."
  sleep 10
done
echo "Istio control plane ready"
oc get pods -n istio-system
```
_Point out: istiod pods show Istio version (1.28.x), not Maistra_

### 4e — Apply mesh-wide mTLS PeerAuthentication

> "MTA told us: `security.dataPlane.mtls: true` in the SMCP becomes a mesh-wide
> PeerAuthentication. One YAML resource, standard upstream API."

```bash
cat <<'EOF' | oc apply -f -
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: default
  namespace: istio-system
spec:
  mtls:
    mode: STRICT
EOF
```

### 4f — Migrate namespace enrollment

> "Replace the SMMR with namespace labels. That's the entire namespace migration."

```bash
# Namespaces already have istio-injection=enabled from earlier
# (This was set during OSSM 2.x setup — the label carries over)
oc get namespace bookinfo custom-app \
  -o jsonpath='{range .items[*]}{.metadata.name}{": istio-injection="}{.metadata.labels.istio-injection}{"\n"}{end}'

# Remove OSSM 2.x enrollment resources — no longer needed
oc delete smmr default -n istio-system
oc delete servicemeshmember default -n custom-app
```

### 4g — Deploy the observability stack (Prometheus + Kiali)

> "In OSSM 2.x, Kiali and Prometheus were bundled inside the SMCP. In OSSM 3, they're
> separate — Kiali via its own operator CR, Prometheus as a standalone deployment.
> This decoupling means each can be upgraded and configured independently."

```bash
# Deploy Prometheus (required by Kiali for the traffic graph)
oc apply -f setup/ossm3/04-prometheus.yaml

until oc get pods -n istio-system -l app=prometheus --no-headers | grep -q '1/1'; do sleep 5; done
echo "Prometheus ready"

# Deploy Kiali, wired to our new Prometheus
cat <<'EOF' | oc apply -f -
apiVersion: kiali.io/v1alpha1
kind: Kiali
metadata:
  name: kiali
  namespace: istio-system
spec:
  istio_namespace: istio-system
  auth:
    strategy: anonymous
  deployment:
    accessible_namespaces:
      - "**"
  external_services:
    prometheus:
      url: "http://prometheus.istio-system:9090"
    istio:
      root_namespace: istio-system
    grafana:
      enabled: false
    tracing:
      enabled: false
EOF

until oc get pods -n istio-system -l app=kiali --no-headers | grep -q '1/1'; do sleep 5; done
echo "Kiali ready: https://$(oc get route kiali -n istio-system -o jsonpath='{.spec.host}')/console/overview"
```

> "To see the traffic graph in Kiali, generate some load first — Prometheus needs at least
> one scrape interval of Istio metrics before the graph populates."

```bash
for i in $(seq 1 20); do
  curl -so /dev/null \
    http://istio-ingressgateway-istio-system.apps.cluster-pt77w.dyn.redhatworkshops.io/productpage
done
```

### 4h — Deploy the ingress gateway

> "In OSSM 2.x the SMCP auto-provisioned the gateway. In OSSM 3 it's a separate Deployment —
> more flexible, but an explicit migration step."

```bash
cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: istio-ingressgateway
  namespace: istio-system
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: istio-ingressgateway
  namespace: istio-system
spec:
  selector:
    matchLabels:
      istio: ingressgateway
  template:
    metadata:
      annotations:
        inject.istio.io/templates: gateway
      labels:
        istio: ingressgateway
        sidecar.istio.io/inject: "true"
    spec:
      serviceAccountName: istio-ingressgateway
      containers:
      - name: istio-proxy
        image: auto
---
apiVersion: v1
kind: Service
metadata:
  name: istio-ingressgateway
  namespace: istio-system
spec:
  type: ClusterIP
  selector:
    istio: ingressgateway
  ports:
  - name: http2
    port: 80
    targetPort: 8080
  - name: https
    port: 443
    targetPort: 8443
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: istio-ingressgateway
  namespace: istio-system
spec:
  host: istio-ingressgateway-istio-system.apps.cluster-pt77w.dyn.redhatworkshops.io
  port:
    targetPort: http2
  to:
    kind: Service
    name: istio-ingressgateway
EOF

until oc get pods -n istio-system -l istio=ingressgateway --no-headers | grep -q '1/1'; do sleep 5; done
echo "Gateway ready"
```

### 4h — Restart pods to pick up OSSM 3 proxy

```bash
# Roll all pods so they pick up the new OSSM 3 istio-proxy
oc rollout restart deployment -n bookinfo
oc rollout restart deployment -n custom-app

# Watch sidecars come back (2/2)
oc get pods -n bookinfo -w
```

---

## Scene 5 — Validation [~5 min]

> "Let's confirm the migration worked."

```bash
# Control plane: both Istio and IstioCNI ready
oc get istio,istiocni -A

# Proxy version — should be OSSM 3 / upstream Istio, NOT maistra
oc get pods -n bookinfo -o jsonpath='{range .items[0:1]}{.metadata.name}{"\t"}{.spec.containers[?(@.name=="istio-proxy")].image}{"\n"}{end}'
# Should show docker.io/istio/proxyv2:1.28.x

# mTLS: app-to-app traffic still works transparently
# (productpage is Python-based — no curl, use python3)
oc exec -n bookinfo deploy/productpage-v1 -c productpage -- \
  python3 -c "import urllib.request; r=urllib.request.urlopen('http://details.bookinfo:9080/details/0'); print('HTTP', r.status)"
# Expected: HTTP 200

# Ingress still works
curl -so /dev/null -w "%{http_code}" \
  http://istio-ingressgateway-istio-system.apps.cluster-pt77w.dyn.redhatworkshops.io/productpage
# Expected: 200

# Confirm no OSSM 2.x control plane instances remain
for r in smcp smmr servicemeshmember; do
  COUNT=$(oc get $r -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
  echo "  $r: ${COUNT} instance(s)"
done
# Expected: all 0 — CRDs still exist but no resources are running
```

**Switch to Kiali (now backed by OSSM 3):**
> "Kiali shows the mesh is healthy — all services connected, mTLS on all edges, and
> the graph shows upstream Istio resource types, not Maistra."

---

## Scene 6 — What's Next: Progress Tracking + Konveyor AI [~4 min, if time permits]

**Switch back to MTA Console**

### 6a — MTA Progress Tracking

> "As your team completes each migration step, you mark findings in MTA as resolved. This gives
> you a living audit trail — mandatory blockers getting ticked off, effort burndown over time,
> full history of who changed what and when."

1. Go to **Applications** → **ossm-mesh-config** → **Reports**
2. Click into a mandatory finding
3. Show the **Mark as resolved** / status workflow

### 6b — What's Next: Konveyor AI (Kai) [slide 13]

**Switch to slide 13 — Konveyor AI**

> "One important thing to call out before we wrap up: MTA and its AI companion — Konveyor AI,
> or Kai — were designed **primarily for application code migration**. Java EE to Quarkus, Spring
> Boot upgrades, .NET Framework to .NET Core. What we did today — analyzing Kubernetes YAML and
> infrastructure manifests — uses MTA's extensible custom rules engine to apply the same discipline
> to a platform migration. That's a newer use case, and it works well for analysis. The
> AI-assisted transformation side is still evolving for YAML."

> "So what does Kai look like in action? Today, MTA told us *what* needs to change and gave us
> remediation guidance. With Kai enabled, the report would also show a **'Get fixes'** button
> next to each finding. Kai takes the finding plus the affected file, sends it to an LLM, and
> generates a proposed YAML transformation — right in the console."

**Point out the progression on slide 13:**

> "For the simpler mandatory findings — removing the ServiceMeshMember, replacing the SMMR with
> namespace labels, creating the mesh-wide PeerAuthentication — Kai produces ready-to-apply YAML.
> For the complex ones like the full SMCP-to-Istio-CR mapping, it generates a solid starting point
> that an engineer reviews and approves. The engineer moves from YAML author to YAML reviewer."

> "Kai isn't enabled in this environment today — it requires connecting an LLM backend — but
> this is the natural next step. MTA finds the issues. Kai generates the fixes. A GitOps pipeline
> like ArgoCD applies them. The human stays in the loop as the approver, not the typist."

**If asked how to enable Kai:**
> "It's a tech preview in MTA 8.x. You enable it via the Tackle CR with an LLM provider — IBM
> WatsonX with Granite models is the Red Hat-supported path, but OpenAI and self-hosted models
> work too. Happy to follow up with the configuration steps after the session."

---

## Timing Summary

| Scene | Topic | Time |
|---|---|---|
| Intro / slides 1–7 | Context + architecture | 10 min |
| Scene 1 | OSSM 2.x running | 5 min |
| Scene 2 | MTA application + findings overview | 8 min |
| Scene 3 | Walking the report | 8 min |
| Scene 4 | Applying migration | 10 min |
| Scene 5 | Validation | 5 min |
| Scene 6 | MTA tracking + Konveyor AI "what's next" | 4 min |
| Q&A | | 10 min |
| **Total** | | **~58 min** |

---

## Troubleshooting / Contingency

**If OSSM 3 operator install is slow:**
Pre-install it before the demo:
```bash
oc apply -f setup/ossm3/01-ossm3-operator.yaml
```
During the demo, just show `oc get csv -n openshift-operators | grep servicemeshoperator3`.

**If Istio control plane takes more than 3 min to be ready:**
```bash
# Check what's blocking
oc get pods -n istio-system
oc describe istio default
```

**If pods don't get new sidecars after restart:**
```bash
# Confirm the mutating webhook was updated by OSSM 3
oc get mutatingwebhookconfiguration | grep istio
# Force delete and recreate pods if needed
oc delete pod -n bookinfo --all
```

**If the bookinfo ingress route is gone after SMCP deletion:**
```bash
# OSSM 3 creates its own gateway service — may need a new route
oc expose svc istio-ingressgateway -n istio-system
```

**For questions about zero-downtime production migration:**
> "In production, use `IstioRevision` for a canary approach: install a new revision alongside
> the old SMCP, migrate one namespace at a time by updating its revision label, then delete
> the SMCP last. No downtime, fully reversible at each step."

---

## Key Talking Points (Pocket Reference)

- **MTA extensibility**: No built-in OSSM target, so we created custom Kantra rules — this is exactly how customers add their own infra migration rules
- **21 story points** found across 8 findings — without MTA this is a day+ of YAML audit work
- **4 mandatory blockers** map 1:1 to clear actions; MTA gives you the exact replacement YAML
- **OSSM 3 tracks upstream Istio** — faster releases, no Maistra fork, Gateway API first class
- **Namespace enrollment by label** is GitOps-friendly; SMMR required a central admin to manage membership
- **mTLS config moves to PeerAuthentication** — standard upstream API, no proprietary SMCP fields
- **sailoperator.io/v1 API** — same CRDs as upstream community Sail Operator, Red Hat supported via servicemeshoperator3
- **IstioRevision canary** = zero-downtime production migrations
