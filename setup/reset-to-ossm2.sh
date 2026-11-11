#!/usr/bin/env bash
# Reset demo environment from OSSM 3 back to OSSM 2.x
# Safe to run multiple times. Takes ~3-4 minutes.
set -e

echo "=== Step 1: Remove OSSM 3 control plane ==="
oc delete istio default 2>/dev/null && echo "  Istio CR deleted" || echo "  Istio CR not found (OK)"
oc delete istiocni default -n istio-cni 2>/dev/null && echo "  IstioCNI CR deleted" || echo "  IstioCNI CR not found (OK)"

# Wait for OSSM 3 istiod to terminate before bringing OSSM 2.x back up
echo "  Waiting for OSSM 3 istiod to terminate..."
until ! oc get pods -n istio-system -l app=istiod --no-headers 2>/dev/null | grep -q Running; do
  sleep 5
done
echo "  istiod cleared"

echo ""
echo "=== Step 2: Remove OSSM 3 standalone components ==="
oc delete deployment istio-ingressgateway -n istio-system 2>/dev/null || true
oc delete service istio-ingressgateway -n istio-system 2>/dev/null || true
oc delete route istio-ingressgateway -n istio-system 2>/dev/null || true
oc delete serviceaccount istio-ingressgateway -n istio-system 2>/dev/null || true
oc delete kiali kiali -n istio-system 2>/dev/null || true
oc delete deployment prometheus -n istio-system 2>/dev/null || true
oc delete service prometheus -n istio-system 2>/dev/null || true
oc delete serviceaccount prometheus -n istio-system 2>/dev/null || true
oc delete configmap prometheus-config -n istio-system 2>/dev/null || true
oc delete clusterrole istio-prometheus 2>/dev/null || true
oc delete clusterrolebinding istio-prometheus 2>/dev/null || true
echo "  Standalone components removed"

echo ""
echo "=== Step 3: Remove OSSM 3 mesh-wide PeerAuthentication ==="
# This was created as part of the OSSM 3 migration — OSSM 2.x manages mTLS via SMCP instead
oc delete peerauthentication default -n istio-system 2>/dev/null && echo "  Mesh-wide PA removed" || echo "  Mesh-wide PA not found (OK)"

echo ""
echo "=== Step 4: Delete istio-cni namespace ==="
oc delete namespace istio-cni --ignore-not-found
echo "  istio-cni namespace removed"

echo ""
echo "=== Step 5: Restore OSSM 2.x control plane (SMCP + SMMR) ==="
oc apply -f setup/ossm2/01-control-plane.yaml

echo "  Waiting for SMCP to be ready (~2-3 minutes)..."
until oc get smcp basic -n istio-system \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q True; do
  READY=$(oc get smcp basic -n istio-system \
    -o jsonpath='{.status.readiness.components.ready}/{.status.readiness.components.total}' 2>/dev/null)
  echo "  SMCP: $READY components ready..."
  sleep 15
done
echo "  SMCP ready"

echo ""
echo "=== Step 6: Restore ServiceMeshMember for custom-app ==="
oc apply -f setup/apps/custom-app.yaml 2>/dev/null | grep -i 'servicemeshmember\|configured\|created' || true

echo ""
echo "=== Step 7: Wait for SMMR to enroll namespaces ==="
until oc get smmr default -n istio-system \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q True; do
  sleep 10
done
echo "  SMMR Ready — bookinfo and custom-app enrolled"

echo ""
echo "=== Step 8: Restart pods to pick up OSSM 2.x proxy ==="
oc rollout restart deployment -n bookinfo
oc rollout restart deployment -n custom-app

echo "  Waiting for rollout to complete (uses rollout status, not pod count)..."
for deploy in details-v1 productpage-v1 ratings-v1 reviews-v1 reviews-v2 reviews-v3; do
  oc rollout status deployment/$deploy -n bookinfo --timeout=120s
done
oc rollout status deployment/httpbin -n custom-app --timeout=60s
echo "  Pods ready"

echo ""
echo "=== Waiting for Kiali to be restored by SMCP ==="
until oc get route kiali -n istio-system &>/dev/null; do sleep 5; done
echo "  Kiali route ready"

echo ""
echo "=== Reset complete ==="
echo ""
echo "Verify:"
oc get smcp -n istio-system
echo ""
oc get pods -n istio-system
echo ""
oc get pods -n bookinfo --no-headers | awk '{print $1, $2}'
echo ""
PROXY_IMAGE=$(oc get pod -n bookinfo -l app=productpage \
  -o jsonpath='{range .items[-1:]}{.spec.containers[?(@.name=="istio-proxy")].image}{end}' 2>/dev/null)
echo "Proxy image: $PROXY_IMAGE"
echo "(OSSM 2.x = 'proxyv2-rhel9' without 'istio-' prefix)"
echo "(OSSM 3.x = 'istio-proxyv2-rhel9' with 'istio-' prefix)"
echo ""
echo "Bookinfo URL:"
echo "  http://$(oc get route istio-ingressgateway -n istio-system -o jsonpath='{.spec.host}')/productpage"
echo ""
echo "Kiali URL:"
echo "  https://$(oc get route kiali -n istio-system -o jsonpath='{.spec.host}')"
