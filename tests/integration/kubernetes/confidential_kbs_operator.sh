#!/usr/bin/env bash
#
# Copyright (c) 2024 Red Hat
#
# SPDX-License-Identifier: Apache-2.0
#
# KBS management backend for operator-managed deployments (e.g. Red Hat build
# of Trustee on OpenShift). Resources are managed through K8s Secrets and
# ConfigMaps as documented in the RH OSC 1.12 guide, since the operator
# disables the KBS admin API.
#
# Select this backend by setting: KBS_MANAGEMENT=operator
#
# Required env vars beyond the ones in confidential_kbs.sh:
#   KBS_DEPLOYMENT  - name of the KBS deployment (default: trustee-deployment)
#   KBS_CONFIG_NAME - name of the KbsConfig CR (default: trustee-config-kbs-config)
#

KBS_DEPLOYMENT="${KBS_DEPLOYMENT:-trustee-deployment}"
KBS_CONFIG_NAME="${KBS_CONFIG_NAME:-trustee-config-kbs-config}"
KBS_RESOURCE_POLICY_CM="${KBS_RESOURCE_POLICY_CM:-trustee-config-resource-policy}"

# Override service discovery for operator-managed KBS. The shared
# kbs_k8s_svc_host/port functions assume nodePort which doesn't exist
# for ClusterIP services. Use the in-cluster DNS name instead.
kbs_k8s_svc_http_addr() {
	local port
	port=$(kubectl get svc "${KBS_SVC_NAME}" -n "${KBS_NS}" \
		-o jsonpath='{.spec.ports[0].port}' 2>/dev/null || echo "8080")
	echo "http://${KBS_SVC_NAME}.${KBS_NS}.svc.cluster.local:${port}"
}

# Set resources policy.
#
# Updates the resource policy ConfigMap and kills the KBS process inside the
# pod so it restarts and picks up the new policy. This is faster than a full
# rollout restart (~5s vs ~30s).
#
# Parameters:
#	$1 - path to policy file
#
kbs_set_resources_policy() {
	local file="${1:-}"

	if [[ ! -f "${file}" ]]; then
		>&2 echo "ERROR: policy file '${file}' does not exist"
		return 1
	fi

	echo "Setting KBS resource policy from ${file}"
	kubectl create configmap "${KBS_RESOURCE_POLICY_CM}" \
		--from-file=policy.rego="${file}" \
		-n "${KBS_NS}" \
		--dry-run=client -o yaml | kubectl apply -f -

	kubectl rollout restart deployment "${KBS_DEPLOYMENT}" -n "${KBS_NS}"
	kubectl rollout status deployment "${KBS_DEPLOYMENT}" -n "${KBS_NS}" --timeout=120s
	sleep 5
}

# Execute an admin command. Not supported with operator-managed KBS since
# the admin API is disabled (type=DenyAll).
#
kbs_config_command() {
	>&2 echo "WARNING: kbs_config_command is not supported with operator-managed KBS, skipping: $*"
	return 0
}

# Set resource, read data from file.
#
# Creates a K8s Secret and registers it in the KbsConfig CR's
# kbsSecretResources list. Only triggers a rollout restart when adding
# a new secret for the first time.
#
# Parameters:
#	$1 - repository name (optional)
#	$2 - resource type (mandatory)
#	$3 - tag (mandatory)
#	$4 - resource file path
#
kbs_set_resource_from_file() {
	local repository="${1:-}"
	local type="${2:-}"
	local tag="${3:-}"
	local file="${4:-}"

	if [[ -z "${type}" || -z "${tag}" ]]; then
		>&2 echo "ERROR: missing type='${type}' and/or tag='${tag}' parameters"
		return 1
	elif [[ ! -f "${file}" ]]; then
		>&2 echo "ERROR: resource file '${file}' does not exist"
		return 1
	fi

	echo "Setting KBS resource: ${repository}/${type}/${tag}"

	kubectl create secret generic "${type}" \
		--from-file="${tag}=${file}" \
		-n "${KBS_NS}" \
		--dry-run=client -o yaml | kubectl apply -f -

	local current
	current=$(kubectl get kbsconfig "${KBS_CONFIG_NAME}" -n "${KBS_NS}" \
		-o jsonpath='{.spec.kbsSecretResources[*]}' 2>/dev/null || true)

	if ! echo " ${current} " | grep -q " ${type} "; then
		echo "Adding '${type}' to kbsSecretResources"
		kubectl patch kbsconfig "${KBS_CONFIG_NAME}" -n "${KBS_NS}" \
			--type=json \
			-p="[{\"op\":\"add\",\"path\":\"/spec/kbsSecretResources/-\",\"value\":\"${type}\"}]"
		# New secret requires a restart for the operator to mount it
		kubectl rollout restart deployment "${KBS_DEPLOYMENT}" -n "${KBS_NS}"
		kubectl rollout status deployment "${KBS_DEPLOYMENT}" -n "${KBS_NS}" --timeout=120s
		sleep 5
	fi
}

# Delete a KBS resource Secret and unregister it from kbsSecretResources.
#
# This ensures kbs_set_resource_from_file will treat the next provision
# as a fresh addition and trigger a rollout restart.
#
# Parameters:
#	$1 - repository name (unused, for API compatibility)
#	$2 - resource type (mandatory) — the Secret name
#	$3 - tag (optional, unused — the entire Secret is deleted)
#
kbs_delete_resource() {
	local type="${2:-}"

	if [[ -z "${type}" ]]; then
		>&2 echo "ERROR: missing type parameter"
		return 1
	fi

	echo "Deleting KBS resource secret: ${type}"
	kubectl delete secret "${type}" -n "${KBS_NS}" --ignore-not-found

	# Remove from kbsSecretResources so the next kbs_set_resource_from_file
	# treats it as new and triggers a rollout restart.
	local current idx
	current=$(kubectl get kbsconfig "${KBS_CONFIG_NAME}" -n "${KBS_NS}" \
		-o jsonpath='{.spec.kbsSecretResources[*]}' 2>/dev/null || true)

	idx=0
	for name in ${current}; do
		if [[ "${name}" == "${type}" ]]; then
			echo "Removing '${type}' from kbsSecretResources (index ${idx})"
			kubectl patch kbsconfig "${KBS_CONFIG_NAME}" -n "${KBS_NS}" \
				--type=json \
				-p="[{\"op\":\"remove\",\"path\":\"/spec/kbsSecretResources/${idx}\"}]" 2>/dev/null || true
			break
		fi
		idx=$((idx + 1))
	done
}

# Override policy helpers for operator-managed KBS.
# The upstream sample policies (allow_all.rego, default.rego) reference
# `data.plugin` which is populated by the kbs-client-deployed KBS but not
# by the Trustee operator's KBS. Use inline policies with `default allow`
# instead.
kbs_set_allow_all_resources() {
	local policy_file
	policy_file=$(mktemp -t kbs-policy-XXXXX.rego)
	cat > "${policy_file}" <<-'EOREGO'
		package policy
		default allow = true
	EOREGO
	kbs_set_resources_policy "${policy_file}"
	rm -f "${policy_file}"
}

kbs_set_deny_all_resources() {
	local policy_file
	policy_file=$(mktemp -t kbs-policy-XXXXX.rego)
	cat > "${policy_file}" <<-'EOREGO'
		package policy
		default allow = false
	EOREGO
	kbs_set_resources_policy "${policy_file}"
	rm -f "${policy_file}"
}

kbs_set_default_policy() {
	kbs_set_allow_all_resources
}

# Build and install the kbs-client binary. Not needed for operator backend.
#
kbs_install_cli() {
	echo "kbs-client is not needed with operator-managed KBS"
}

kbs_uninstall_cli() {
	true
}

# Deploy KBS. With operator-managed KBS this is a no-op since the operator
# handles deployment via the TrusteeConfig/KbsConfig CRs.
#
function kbs_k8s_deploy() {
	echo "KBS is managed by the Trustee operator — skipping direct deployment"
}

# Delete KBS. With operator-managed KBS this is a no-op.
#
function kbs_k8s_delete() {
	echo "KBS is managed by the Trustee operator — skipping deletion"
}
