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

KBS_NS="${KBS_NS:-coco-tenant}"
KBS_SVC_NAME="${KBS_SVC_NAME:-kbs}"
KBS_DEPLOYMENT="${KBS_DEPLOYMENT:-trustee-deployment}"
KBS_CONFIG_NAME="${KBS_CONFIG_NAME:-trustee-config-kbs-config}"
KBS_RESOURCE_POLICY_CM="${KBS_RESOURCE_POLICY_CM:-trustee-config-resource-policy}"

# Execute the same argument vector as the client backend, but on the selected
# worker. Preserve kubectl's exit status through CRI-O CR removal.
kbs_host_exec() {
	local pod_name
	pod_name=$(create_debugger_pod "${node}")
	kubectl exec -qi -n kube-system "${pod_name}" -- chroot /host "$@" | tr -d '\r'
	return "${PIPESTATUS[0]}"
}

kbs_copy_host_file() {
	local source="$1" destination="$2"
	local pod_name
	pod_name=$(create_debugger_pod "${node}")
	kubectl exec -n kube-system "${pod_name}" -- cat "/host/${source#/}" > "${destination}"
}

# RHCOS workers use a pinned prebuilt release, cached on the test driver and
# copied through the debugger pod. No Rust installation is needed on either.
ensure_snphost() {
	if [[ -n "${KBS_SNPHOST_DIR:-}" ]]; then
		[[ "${KBS_SNPHOST_NODE}" == "${node}" ]] || {
			>&2 echo "ERROR: snphost was staged on '${KBS_SNPHOST_NODE}', but the test runs on '${node}'"
			return 1
		}
		return 0
	fi
	local version="0.7.0"
	local checksum="eab3c3bcba9ee85cb1c5108c92b82a5cf068d90c5aee1b43301bc57e152cd6ee"
	local cache_dir="${XDG_CACHE_HOME:-${HOME}/.cache}/kata-containers/snphost-${version}"
	local binary="${cache_dir}/snphost"
	mkdir -p "${cache_dir}"
	if [[ ! -f "${binary}" ]] || \
			! printf '%s  %s\n' "${checksum}" "${binary}" | sha256sum -c - >/dev/null 2>&1; then
		local download="${BATS_TEST_TMPDIR:?}/snphost"
		curl -fsSL --retry 3 --connect-timeout 30 --max-time 180 \
			"https://github.com/virtee/snphost/releases/download/v${version}/snphost" -o "${download}"
		printf '%s  %s\n' "${checksum}" "${download}" | sha256sum -c -
		chmod 755 "${download}"
		mv "${download}" "${binary}"
	fi
	KBS_SNPHOST_NODE="${node}"
	KBS_SNPHOST_DIR=$(kbs_host_exec mktemp -d /var/tmp/kata-snphost.XXXXXX)
	SNPHOST_BINARY="${KBS_SNPHOST_DIR}/snphost"
	copy_file_to_host "${binary}" "${node}" "${SNPHOST_BINARY}"
	kbs_host_exec chmod 755 "${SNPHOST_BINARY}"
	kbs_host_exec "${SNPHOST_BINARY}" --version
	kbs_host_exec test -c /dev/sev
	echo "Staged snphost on ${node} at ${SNPHOST_BINARY}"
}

kbs_prepare_snp_reference_values() {
	KBS_OPERATOR_REFERENCE_VALUES_BACKUP="${BATS_TEST_TMPDIR:?}/reference-values.json"
	kbs_save_reference_values "${KBS_OPERATOR_REFERENCE_VALUES_BACKUP}"
}

# Called by teardown, including when measurement or resource retrieval fails.
kbs_snp_cleanup() {
	local rc=0
	if [[ -n "${KBS_SNPHOST_DIR:-}" ]]; then
		local node="${KBS_SNPHOST_NODE}"
		if kbs_host_exec rm -rf "${KBS_SNPHOST_DIR}"; then
			unset KBS_SNPHOST_DIR KBS_SNPHOST_NODE SNPHOST_BINARY
		else
			rc=$?
		fi
	fi
	if [[ -f "${KBS_OPERATOR_REFERENCE_VALUES_BACKUP:-}" ]]; then
		kbs_restore_reference_values "${KBS_OPERATOR_REFERENCE_VALUES_BACKUP}" || rc=$?
	fi
	return "${rc}"
}

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
		--from-file=resource-policy.rego="${file}" \
		-n "${KBS_NS}" \
		--dry-run=client -o yaml | kubectl apply -f -

	kubectl rollout restart deployment "${KBS_DEPLOYMENT}" -n "${KBS_NS}"
	kubectl rollout status deployment "${KBS_DEPLOYMENT}" -n "${KBS_NS}" --timeout=120s
	sleep 5
}

# Reference values are managed through the operator's LocalJson ConfigMap.
kbs_reference_values_configmap() {
	kubectl get kbsconfig "${KBS_CONFIG_NAME}" -n "${KBS_NS}" \
		-o jsonpath='{.spec.kbsRvpsRefValuesConfigMapName}'
}

kbs_save_reference_values() {
	kubectl get configmap "$(kbs_reference_values_configmap)" -n "${KBS_NS}" \
		-o json | jq -r '.data.reference_value' > "$1"
}

kbs_restore_reference_values() {
	local patch
	patch=$(jq -n --rawfile values "$1" '{data: {reference_value: $values}}')
	kubectl patch configmap "$(kbs_reference_values_configmap)" -n "${KBS_NS}" \
		--type=merge -p "${patch}" || return
	kubectl rollout restart deployment "${KBS_DEPLOYMENT}" -n "${KBS_NS}" || return
	kubectl rollout status deployment "${KBS_DEPLOYMENT}" -n "${KBS_NS}" --timeout=120s
}

# Translate the SNP test's sample reference values to LocalJson records.
kbs_config_command() {
	local command="$1"; shift
	if [[ "${command}" != "set-sample-reference-value" ]]; then
		>&2 echo "ERROR: unsupported operator-managed KBS command: ${command}"
		return 1
	fi
	local value_type="string"
	if [[ "${1:-}" == "--as-integer" ]]; then
		value_type="integer"
		shift
	fi
	local name="$1" value="$2" file expiration
	file=$(mktemp)
	kbs_save_reference_values "${file}"
	expiration=$(date -u -d '+1 day' +%Y-%m-%dT%H:%M:%SZ)
	local updated
	# LocalJson stores a map of names to base64url-encoded serialized RV records.
	updated=$(jq --arg name "${name}" --arg value "${value}" \
		--arg type "${value_type}" --arg expiration "${expiration}" \
		'.[$name] = ({version: "0.1.0", name: $name, expiration: $expiration,
		value: [($value | if $type == "integer" then tonumber else . end)]}
		| tojson | @base64 | gsub("\\+"; "-") | gsub("/"; "_"))' "${file}")
	printf '%s\n' "${updated}" > "${file}"
	kbs_restore_reference_values "${file}"
	rm -f "${file}"
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
