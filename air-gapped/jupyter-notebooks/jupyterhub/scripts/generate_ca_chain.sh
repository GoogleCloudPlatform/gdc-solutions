#!/bin/bash
# generate_ca_chain.sh
# Generates the complete secure CA chain required for JupyterHub to verify the Kubernetes API server securely.

NAMESPACE="${JUPYTERHUB_NAMESPACE}"
OUTPUT_FILE="${GDC_SOLUTION_HOME}/ca-chain.crt"

echo "========================================="
echo "Generating secure API server CA chain..."
echo "========================================="

# 1. Get the ServiceAccount CA (dev-ca-full-ca) from the local namespace
echo "[1/3] Extracting ServiceAccount CA from kube-root-ca.crt..."
SA_CA=$(kubectl get configmap kube-root-ca.crt -n "$NAMESPACE" -o jsonpath='{.data.ca\.crt}')

if [ -z "$SA_CA" ]; then
  echo "ERROR: Failed to retrieve kube-root-ca.crt from namespace $NAMESPACE"
  exit 1
fi

# 2. Extract the intermediate GDC Managed Org Internal Primary CA certificate
echo "[2/3] Extracting GDC Managed Org Internal Primary CA from clustermesh-bundle..."
PRIMARY_CA=$(kubectl get configmap clustermesh-bundle -n kube-system -o jsonpath='{.data.ca\.crt}' |
  awk '/BEGIN CERTIFICATE/ { i++ } i == 2 { print }')

if [ -z "$PRIMARY_CA" ]; then
  echo "ERROR: Failed to extract GDC Managed Org Internal Primary CA from clustermesh-bundle in kube-system"
  exit 1
fi

# 3. Extract the GDC Managed Org Internal Root CA certificate
echo "[3/3] Extracting GDC Managed Org Internal Root CA from trust-store-org-global-internal-only..."
ROOT_CA=$(kubectl get configmap trust-store-org-global-internal-only -n "$NAMESPACE" -o jsonpath='{.data.ca\.crt}')

if [ -z "$ROOT_CA" ]; then
  echo "ERROR: Failed to extract GDC Managed Org Internal Root CA from trust-store-org-global-internal-only"
  exit 1
fi

# Combine the certificates in hierarchical order
echo "--> Combining certificates into $OUTPUT_FILE..."
cat << EOF > "$OUTPUT_FILE"
$SA_CA
$PRIMARY_CA
$ROOT_CA
EOF

echo "--> Verifying certificate chain using openssl..."
# A successful chain verification will exit 0
if openssl verify -CAfile "$OUTPUT_FILE" "$OUTPUT_FILE" > /dev/null 2>&1; then
  echo "SUCCESS: Cryptographic chain is complete and verified."
else
  echo "WARNING: Openssl verification failed. Double-check your cluster certificate layout."
fi

# Apply the chain as a ConfigMap in Kubernetes
echo "--> Applying ConfigMap 'gdc-ca-chain' in namespace $NAMESPACE..."
kubectl create configmap gdc-ca-chain \
  --from-file=ca-chain.crt="$OUTPUT_FILE" \
  -n "$NAMESPACE" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "========================================="
echo "Done! The CA chain is ready and active."
echo "========================================="
