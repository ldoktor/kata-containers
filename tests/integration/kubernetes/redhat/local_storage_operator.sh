#!/bin/bash
#
# Helper functions for managing the Local Storage Operator on OCP.
#

LOCAL_STORAGE_NS="openshift-local-storage"

is_local_storage_operator_installed() {
	kubectl get deployment local-storage-operator \
		-n "${LOCAL_STORAGE_NS}" &>/dev/null
}

install_local_storage_operator() {
	if is_local_storage_operator_installed; then
		echo "Local Storage Operator already installed"
		return 0
	fi

	echo "=== Installing Local Storage Operator ==="

	echo "Creating namespace ${LOCAL_STORAGE_NS}"
	oc adm new-project "${LOCAL_STORAGE_NS}" 2>/dev/null || true

	echo "Creating OperatorGroup"
	kubectl apply -f - <<-'EOF'
	apiVersion: operators.coreos.com/v1
	kind: OperatorGroup
	metadata:
	  name: local-operator-group
	  namespace: openshift-local-storage
	spec:
	  targetNamespaces:
	  - openshift-local-storage
	EOF

	echo "Creating Subscription"
	kubectl apply -f - <<-'EOF'
	apiVersion: operators.coreos.com/v1alpha1
	kind: Subscription
	metadata:
	  name: local-storage-operator
	  namespace: openshift-local-storage
	spec:
	  channel: stable
	  installPlanApproval: Automatic
	  name: local-storage-operator
	  source: redhat-operators
	  sourceNamespace: openshift-marketplace
	EOF

	echo "Waiting for operator deployment to be created..."
	local elapsed=0
	local poll=5
	local max_wait=120
	while ! is_local_storage_operator_installed; do
		if (( elapsed >= max_wait )); then
			echo "ERROR: Local Storage Operator deployment not created after ${max_wait}s" >&2
			return 1
		fi
		sleep "${poll}"
		elapsed=$((elapsed + poll))
	done

	echo "Waiting for operator to become available..."
	kubectl wait --for=condition=Available \
		deployment/local-storage-operator \
		-n "${LOCAL_STORAGE_NS}" \
		--timeout=300s

	echo "Local Storage Operator installed successfully"
}
