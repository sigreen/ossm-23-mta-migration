# Slides Outline: Migrating OSSM 2.x to OSSM 3.x with MTA 8.3.3

---

## Slide 1 — Title

**Modernizing Your Service Mesh: Migrating OpenShift Service Mesh 2.x to 3.x with Migration Toolkit for Applications**

- Speaker / Date
- Environment: OCP 4.18.56 | MTA 8.3.3

---

## Slide 2 — Agenda

1. Why migrate from OSSM 2.x to OSSM 3.x?
2. What changed: architecture & API differences
3. Migration challenges without tooling
4. MTA 8.3.3 overview and OSSM migration rules
5. Live demo walkthrough
6. Results and validation
7. Next steps & resources

---

## Slide 3 — OSSM 2.x Architecture Overview

**Key components:**
- Maistra fork of Istio (diverged from upstream)
- `ServiceMeshControlPlane` (SMCP) — custom CRD wrapping Istio config
- `ServiceMeshMemberRoll` (SMMR) — explicit namespace enrollment
- `ServiceMeshMember` — per-namespace opt-in
- Bundled Jaeger, Kiali, Prometheus as SMCP sub-components
- OpenShift-specific CNI plugin via SMCP

**Pain points with 2.x:**
- Lag behind upstream Istio feature velocity
- Proprietary SMCP API diverges from upstream IstioOperator
- Namespace enrollment requires manual SMMR management
- Bundled observability stack creates upgrade coupling

> _Diagram: OCP cluster → SMCP → namespaces enrolled via SMMR → Envoy sidecars_

---

## Slide 4 — OSSM 3.x Architecture Overview

**Key components:**
- Based on upstream Istio — no Maistra fork
- **Sail Operator** manages the Istio control plane via upstream-aligned CRDs
- `Istio` CR replaces SMCP
- `IstioCNI` CR replaces CNI section of SMCP
- `IstioRevision` for canary/multi-revision deployments
- Namespace discovery: labels (`istio-injection=enabled`) or `DiscoverySelectors`
- Kubernetes Gateway API (preferred) alongside classic Istio Gateway
- Decoupled observability — Tempo, Kiali installed separately

**Benefits:**
- Tracks upstream Istio releases closely
- Standard `IstioOperator` / Helm values pattern
- Gateway API first class — future-proof
- Cleaner upgrade path via revisions

> _Diagram: Sail Operator → Istio CR → IstioCNI CR → labelled namespaces → Envoy sidecars_

---

## Slide 5 — Key Differences That Make Manual Migration Hard

| Area | OSSM 2.x | OSSM 3.x |
|---|---|---|
| Control plane CRD | `ServiceMeshControlPlane` | `Istio` (Sail Operator) |
| Namespace enrollment | `ServiceMeshMemberRoll` | namespace labels / DiscoverySelectors |
| CNI config | Embedded in SMCP | Separate `IstioCNI` CR |
| Ingress gateway | SMCP `gateways` section | `Gateway` CR (Gateway API) or classic |
| mTLS policy | SMCP `security.dataPlane.mtls` | `PeerAuthentication` + mesh-wide default |
| Telemetry / tracing | SMCP `addons.jaeger` | `Telemetry` CR + external Tempo/OTLP |
| Kiali | SMCP addon | Separate Kiali Operator subscription |
| Extensions (WASM) | `ServiceMeshExtension` (deprecated) | `WasmPlugin` |
| `EnvoyFilter` | Supported, some Maistra fields | Upstream-only fields |
| Multi-tenancy | Implicit via SMMR | Explicit via `DiscoverySelectors` |

**Result:** Dozens of YAML files must be found, understood, and reworked — MTA automates the discovery and triage.

---

## Slide 6 — Migration Toolkit for Applications (MTA) Overview

**What is MTA?**
- Red Hat's application and platform modernization analysis tool (formerly Windup)
- v8.3.3 — available as an operator on OCP, includes web console + CLI (`mta-cli`)

**How MTA helps with OSSM migration:**
- Ships built-in **OSSM 2→3 ruleset** (`ossm-migration` technology tag)
- Scans: Kubernetes/OpenShift YAML manifests, Helm charts, Kustomize overlays, operator configs
- Produces: categorized findings (mandatory / optional / information), effort estimates, remediation guidance
- Generates: transformed output YAML where automated fixes are possible
- Tracks: migration progress per application / per cluster scope

**MTA analysis modes for this use case:**
- **Source analysis** — scan Git repos or uploaded archives containing mesh config
- **Binary/manifest analysis** — point at a live namespace export or archive of `oc get -o yaml` output

---

## Slide 7 — Demo Architecture

```
┌────────────────────────────────────────────────────┐
│  OCP 4.18.56 Cluster                               │
│                                                    │
│  ┌──────────────┐    ┌──────────────────────────┐  │
│  │ OSSM 2.6.x   │    │  MTA 8.3.3 (Operator)    │  │
│  │ istio-system │    │  mta namespace            │  │
│  │  SMCP        │    │  Web Console              │  │
│  │  SMMR        │    │  mta-cli                  │  │
│  └──────────────┘    └──────────────────────────┘  │
│                                                    │
│  ┌────────────────────────────────────────────┐    │
│  │ bookinfo namespace (enrolled in mesh)      │    │
│  │  productpage / details / reviews / ratings │    │
│  │  VirtualService / DestinationRule / Gateway│    │
│  └────────────────────────────────────────────┘    │
│                                                    │
│  ┌────────────────────────────────────────────┐    │
│  │ custom-app namespace                       │    │
│  │  ServiceMeshMember CR                      │    │
│  │  mTLS PeerAuthentication                   │    │
│  │  AuthorizationPolicy                       │    │
│  │  WasmPlugin (via old ServiceMeshExtension) │    │
│  └────────────────────────────────────────────┘    │
└────────────────────────────────────────────────────┘
```

**Demo goal:** Use MTA to analyze the OSSM 2.x configuration, review findings, apply generated transforms, install OSSM 3.x via Sail Operator, and validate traffic flows.

---

## Slide 8 — Demo Flow (Live)

_[This slide is a visual roadmap shown during the demo — advance each step as you complete it]_

```
Step 1: Show OSSM 2.x running
   └─► oc get smcp, smmr, servicemeshmember -A

Step 2: Export mesh configuration to archive
   └─► oc get all -o yaml > mesh-config.tar.gz

Step 3: Create MTA project & upload archive
   └─► MTA Web Console → New Project → Upload

Step 4: Run OSSM 2→3 analysis
   └─► MTA applies ossm-migration ruleset

Step 5: Review MTA report
   └─► Mandatory / Optional / Information findings

Step 6: Download & apply transforms
   └─► Generated Istio, IstioCNI, Gateway YAML

Step 7: Install Sail Operator + OSSM 3.x
   └─► oc apply -f sail-subscription.yaml
   └─► oc apply -f istio-cr.yaml

Step 8: Migrate namespaces (labels + DiscoverySelectors)
   └─► Remove SMMR, apply namespace labels

Step 9: Validate traffic in bookinfo + custom-app
   └─► curl / Kiali topology view
```

---

## Slide 9 — MTA Report: What You'll See

**Categories of findings (live screenshot):**

- **Mandatory** — Must fix before migration can proceed
  - `ServiceMeshControlPlane` → must be replaced by `Istio` CR
  - `ServiceMeshMemberRoll` → must be replaced by namespace labels or DiscoverySelectors
  - `ServiceMeshExtension` → must be replaced by `WasmPlugin`
  - `ServiceMeshMember` → redundant, namespace label replaces it

- **Optional** — Recommended but not blocking
  - Migrate to Kubernetes Gateway API from classic `Gateway`/`VirtualService`
  - Externalize Jaeger → OpenTelemetry Collector + Tempo
  - Externalize Kiali via Kiali Operator

- **Information** — No action required, awareness only
  - `AuthorizationPolicy` / `PeerAuthentication` — APIs unchanged, review for mesh-wide defaults
  - `EnvoyFilter` — Supported, but verify Maistra-specific fields removed

**Effort estimate:** MTA provides story-point estimates per finding category.

---

## Slide 10 — Side-by-Side: Before & After YAML

**SMCP → Istio CR (key excerpt)**

```yaml
# OSSM 2.x — ServiceMeshControlPlane
apiVersion: maistra.io/v2
kind: ServiceMeshControlPlane
metadata:
  name: basic
  namespace: istio-system
spec:
  version: v2.6
  security:
    dataPlane:
      mtls: true
  tracing:
    type: Jaeger
    sampling: 10000
  addons:
    jaeger:
      install:
        storage:
          type: Memory
    kiali:
      enabled: true
  gateways:
    ingress:
      enabled: true
```

```yaml
# OSSM 3.x — Istio CR (Sail Operator)
apiVersion: sailoperator.io/v1alpha1
kind: Istio
metadata:
  name: default
  namespace: istio-system
spec:
  version: v1.24.x
  namespace: istio-system
  updateStrategy:
    type: InPlace
  values:
    meshConfig:
      defaultConfig:
        tracing: {}          # externalized via Telemetry CR
    pilot:
      traceSampling: 1.0
---
apiVersion: sailoperator.io/v1alpha1
kind: IstioCNI
metadata:
  name: default
  namespace: istio-cni
spec:
  version: v1.24.x
  namespace: istio-cni
```

---

## Slide 11 — Namespace Enrollment: Before & After

```yaml
# OSSM 2.x — ServiceMeshMemberRoll
apiVersion: maistra.io/v1
kind: ServiceMeshMemberRoll
metadata:
  name: default
  namespace: istio-system
spec:
  members:
    - bookinfo
    - custom-app
```

```bash
# OSSM 3.x — Label namespaces directly
oc label namespace bookinfo istio-injection=enabled
oc label namespace custom-app istio-injection=enabled

# Or use DiscoverySelectors in Istio CR for fine-grained control
# spec.values.pilot.env.PILOT_ENABLE_NAMESPACE_SCOPING: ...
```

---

## Slide 12 — Validation

**Traffic validation:**
```bash
# Verify sidecar injection in bookinfo
oc get pods -n bookinfo -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .spec.containers[*]}{.name}{" "}{end}{"\n"}{end}'

# Check control plane
oc get istio -n istio-system
oc get istiocni -n istio-cni

# Verify mTLS is active (via PeerAuthentication)
oc get peerauthentication -A

# Hit the productpage
GATEWAY_URL=$(oc get route -n istio-system istio-ingressgateway -o jsonpath='{.spec.host}')
curl -s http://${GATEWAY_URL}/productpage | grep "<title>"
```

**Kiali validation:**
- Mesh topology shows all services connected
- mTLS padlocks visible on edges
- No `maistra.io` resources in the mesh graph

---

## Slide 13 — Summary

**What we demonstrated:**
- MTA 8.3.3 analyzed OSSM 2.x configuration and produced a prioritized migration report
- Mandatory findings guided the control plane migration (SMCP → Istio + IstioCNI)
- Optional findings informed Gateway API and observability stack externalization
- Automated transforms reduced hand-editing of YAML
- Sail Operator + OSSM 3.x installed alongside existing mesh (zero-downtime possible with revision-based approach)
- Application traffic validated post-migration

**Key MTA value:** Removes guesswork — turns a multi-day manual audit into a structured, documented migration with generated starting-point YAML.

---

## Slide 14 — Next Steps & Resources

**Next steps for your environment:**
1. Install MTA 8.3.3 from OperatorHub → `mta` namespace
2. Export your OSSM 2.x configs: `oc get smcp,smmr,servicemeshmember,vs,dr,gw,pa,ap -A -o yaml`
3. Run MTA analysis against the export
4. Plan migration waves by namespace (start with non-prod)
5. Use `IstioRevision` canary approach for zero-downtime production cutover

**Resources:**
- OSSM 3.x Migration Guide: docs.openshift.com (search "Migrate from OSSM 2 to OSSM 3")
- Sail Operator docs: github.com/istio-ecosystem/sail-operator
- MTA 8.3.3 docs: access.redhat.com/documentation/en-us/migration_toolkit_for_applications/8.3
- Upstream Istio 1.24 release notes: istio.io/latest/news/releases

---
