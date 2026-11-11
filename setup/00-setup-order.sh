#!/usr/bin/env bash
# Demo setup script — run once after logging into OCP as cluster-admin
# Order matters: operators → control plane → apps → SCC grants

set -e
OC=${OC:-oc}

echo "=== Step 1: Install OSSM 2.x prerequisite operators ==="
cat <<'EOF' | ${OC} apply -f -
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: kiali-ossm
  namespace: openshift-operators
spec:
  channel: stable
  installPlanApproval: Automatic
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
  installPlanApproval: Automatic
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
  installPlanApproval: Automatic
  name: servicemeshoperator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

echo "Waiting for operators to be ready..."
until ${OC} get csv -n openshift-operators 2>/dev/null | grep -q 'kiali-operator.*Succeeded'; do sleep 10; done
until ${OC} get csv -n openshift-operators 2>/dev/null | grep -q 'jaeger-operator.*Succeeded'; do sleep 10; done
until ${OC} get csv -n openshift-operators 2>/dev/null | grep -q 'servicemeshoperator.*Succeeded'; do sleep 10; done
echo "All OSSM operators ready."

echo ""
echo "=== Step 2: Create OSSM 2.x control plane ==="
${OC} apply -f ossm2/01-control-plane.yaml

echo "Waiting for SMCP to be ready (this takes ~2-3 minutes)..."
until ${OC} get smcp basic -n istio-system \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q 'True'; do
  sleep 15
done
echo "SMCP is Ready."

echo ""
echo "=== Step 3: Deploy bookinfo + custom-app ==="
${OC} apply -f apps/bookinfo.yaml
${OC} apply -f apps/custom-app.yaml

echo ""
echo "=== Step 4: Grant anyuid SCC to bookinfo service accounts ==="
# Required because bookinfo images use runAsUser: 1000 which is outside OCP namespace range
for sa in bookinfo-details bookinfo-ratings bookinfo-reviews bookinfo-productpage; do
  ${OC} adm policy add-scc-to-user anyuid -z $sa -n bookinfo
done
${OC} adm policy add-scc-to-user anyuid -z httpbin -n custom-app

echo ""
echo "=== Step 5: Wait for SMMR to enroll namespaces, then restart pods for injection ==="
until ${OC} get smmr default -n istio-system \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q 'True'; do
  sleep 10
done
echo "SMMR is Ready."

${OC} rollout restart deployment -n bookinfo
${OC} rollout restart deployment -n custom-app

until ${OC} get pods -n bookinfo --no-headers 2>/dev/null | awk '{print $2}' | grep -q '2/2'; do
  sleep 8
done
echo "Sidecars injected successfully."

echo ""
echo "=== Setup complete! ==="
echo "Bookinfo URL: http://$(${OC} get route -n istio-system istio-ingressgateway -o jsonpath='{.spec.host}')/productpage"
echo "Kiali URL:    https://$(${OC} get route -n istio-system kiali -o jsonpath='{.spec.host}')"
echo "MTA URL:      https://$(${OC} get route -n mta mta -o jsonpath='{.spec.host}')"
