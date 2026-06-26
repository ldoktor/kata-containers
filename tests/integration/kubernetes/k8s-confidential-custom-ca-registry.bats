#!/usr/bin/env bats
# Copyright (c) 2026 Red Hat, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#
# Test pulling a container image from a registry with a custom (self-signed)
# CA certificate via the extra_root_certificates field in cdh.toml initdata.

load "${BATS_TEST_DIRNAME}/lib.sh"
load "${BATS_TEST_DIRNAME}/confidential_common.sh"

CUSTOM_CA_REGISTRY_IMAGE="${CUSTOM_CA_REGISTRY_IMAGE:-quay.io/prometheus/busybox:latest}"
CONTAINER_ENGINE="${CONTAINER_ENGINE:-docker}"

setup_file() {
	if ! is_confidential_runtime_class; then
		skip "Test not supported for ${KATA_HYPERVISOR}."
	fi

	# Use a unique suffix so parallel jobs on the same bastion don't collide.
	local unique_suffix="${BATS_ROOT_PID:-$$}"

	CUSTOM_CA_REGISTRY_PORT="${CUSTOM_CA_REGISTRY_PORT:-$(( (unique_suffix % 10000) + 20000 ))}"
	CUSTOM_CA_CONTAINER_NAME="test-custom-ca-registry-${unique_suffix}"
	CUSTOM_CA_CM_NAME="custom-ca-registry-${unique_suffix}"

	# Determine the registry host IP (reachable from the guest VM).
	CUSTOM_CA_REGISTRY_HOST="${CUSTOM_CA_REGISTRY_HOST:-$(hostname -I | awk '{print $1}')}"
	[[ -n "${CUSTOM_CA_REGISTRY_HOST}" ]] || die "Cannot determine registry host IP"

	local cert_dir="${BATS_FILE_TMPDIR}/certs"
	mkdir -p "${cert_dir}/CA"

	# Generate CA key and certificate.
	# NOTE: Rustls does not support self-signed certificates as leaf certs,
	# so a proper CA hierarchy is required.
	local ca_name="TestCA"
	openssl genrsa -out "${cert_dir}/CA/${ca_name}.key" 4096 2>/dev/null
	openssl req -x509 -new -nodes \
		-key "${cert_dir}/CA/${ca_name}.key" \
		-sha256 -days 1 \
		-out "${cert_dir}/CA/${ca_name}.crt" \
		-subj '/CN=Test Root CA/O=TestOrg' 2>/dev/null

	# Generate server key, CSR, and certificate signed by the CA.
	local server_name="server"
	openssl req -new -nodes \
		-out "${cert_dir}/${server_name}.csr" \
		-newkey rsa:4096 \
		-keyout "${cert_dir}/${server_name}.key" \
		-subj "/CN=${CUSTOM_CA_REGISTRY_HOST}/O=TestOrg" 2>/dev/null

	# v3 extensions required by Rustls: basicConstraints, keyUsage, SAN.
	cat > "${cert_dir}/${server_name}.v3.ext" <<-EOF
	authorityKeyIdentifier=keyid,issuer
	basicConstraints=CA:FALSE
	keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
	subjectAltName = @alt_names

	[alt_names]
	IP.1 = ${CUSTOM_CA_REGISTRY_HOST}
	EOF

	openssl x509 -req \
		-in "${cert_dir}/${server_name}.csr" \
		-CA "${cert_dir}/CA/${ca_name}.crt" \
		-CAkey "${cert_dir}/CA/${ca_name}.key" \
		-CAcreateserial \
		-out "${cert_dir}/${server_name}.crt" \
		-days 1 -sha256 \
		-extfile "${cert_dir}/${server_name}.v3.ext" 2>/dev/null

	# Start the TLS-enabled container registry (no auth).
	local volume_opts=":ro"
	if [[ "${CONTAINER_ENGINE}" == "podman" ]]; then
		volume_opts=":Z,ro"
	fi

	${CONTAINER_ENGINE} stop ${CUSTOM_CA_CONTAINER_NAME} 2>/dev/null || true
	${CONTAINER_ENGINE} rm ${CUSTOM_CA_CONTAINER_NAME} 2>/dev/null || true
	${CONTAINER_ENGINE} run -d --name ${CUSTOM_CA_CONTAINER_NAME} \
		-p "${CUSTOM_CA_REGISTRY_PORT}:443" \
		-v "${cert_dir}/${server_name}.crt:/certs/server.crt${volume_opts}" \
		-v "${cert_dir}/${server_name}.key:/certs/server.key${volume_opts}" \
		-e REGISTRY_HTTP_TLS_CERTIFICATE=/certs/server.crt \
		-e REGISTRY_HTTP_TLS_KEY=/certs/server.key \
		-e REGISTRY_HTTP_ADDR=0.0.0.0:443 \
		registry:2
	sleep 2

	# Push the test image to the local registry.
	# Trust the CA locally so the push can verify the registry's TLS cert.
	local push_tls_args=()
	if [[ "${CONTAINER_ENGINE}" == "podman" ]]; then
		push_tls_args=(--tls-verify=false)
	else
		mkdir -p "/etc/docker/certs.d/${CUSTOM_CA_REGISTRY_HOST}:${CUSTOM_CA_REGISTRY_PORT}"
		cp "${cert_dir}/CA/${ca_name}.crt" \
			"/etc/docker/certs.d/${CUSTOM_CA_REGISTRY_HOST}:${CUSTOM_CA_REGISTRY_PORT}/ca.crt"
	fi

	${CONTAINER_ENGINE} pull "${CUSTOM_CA_REGISTRY_IMAGE}" 2>/dev/null || true
	${CONTAINER_ENGINE} tag "${CUSTOM_CA_REGISTRY_IMAGE}" \
		"${CUSTOM_CA_REGISTRY_HOST}:${CUSTOM_CA_REGISTRY_PORT}/test/custom-ca-image:latest"
	${CONTAINER_ENGINE} push "${push_tls_args[@]}" \
		"${CUSTOM_CA_REGISTRY_HOST}:${CUSTOM_CA_REGISTRY_PORT}/test/custom-ca-image:latest"

	# Add the CA cert to OCP's additionalTrustedCA so the host's container
	# runtime can reach the registry for the image metadata pull.
	local registry_key="${CUSTOM_CA_REGISTRY_HOST}..${CUSTOM_CA_REGISTRY_PORT}"
	oc delete configmap ${CUSTOM_CA_CM_NAME} -n openshift-config --ignore-not-found 2>/dev/null
	oc create configmap ${CUSTOM_CA_CM_NAME} -n openshift-config \
		--from-file="${registry_key}=${cert_dir}/CA/${ca_name}.crt"
	oc patch image.config.openshift.io/cluster --type=merge \
		-p "{\"spec\":{\"additionalTrustedCA\":{\"name\":\"${CUSTOM_CA_CM_NAME}\"}}}"

	# Wait for the CA to propagate to the node.
	local node
	node=$(get_one_kata_node)
	waitForProcess 120 5 \
		"exec_host '${node}' 'test -f /etc/docker/certs.d/${CUSTOM_CA_REGISTRY_HOST}:${CUSTOM_CA_REGISTRY_PORT}/ca.crt' 2>/dev/null" \
		|| die "Timed out waiting for CA cert to propagate to node"

	# Export variables for tests.
	export CUSTOM_CA_REGISTRY_HOST CUSTOM_CA_REGISTRY_PORT
	export CUSTOM_CA_CONTAINER_NAME CUSTOM_CA_CM_NAME
	export CUSTOM_CA_CERT_DIR="${cert_dir}"
	export CUSTOM_CA_CERT_CONTENT
	CUSTOM_CA_CERT_CONTENT=$(cat "${cert_dir}/CA/${ca_name}.crt")
}

setup() {
	if ! is_confidential_runtime_class; then
		skip "Test not supported for ${KATA_HYPERVISOR}."
	fi

	setup_common || die "setup_common failed"

	local registry_image="${CUSTOM_CA_REGISTRY_HOST}:${CUSTOM_CA_REGISTRY_PORT}/test/custom-ca-image:latest"
	policy_settings_dir="$(create_tmp_policy_settings_dir "${pod_config_dir}")"

	export CUSTOM_CA_REGISTRY_IMAGE_REF="${registry_image}"
}

@test "Pull image from custom CA registry with extra_root_certificates" {
	local cdh_image_section
	cdh_image_section=$(cat <<-EOF
	[image]
	extra_root_certificates = ["""
	${CUSTOM_CA_CERT_CONTENT}
	"""]
	EOF
	)

	local initdata
	initdata=$(get_initdata_with_cdh_image_section "${cdh_image_section}")

	create_coco_pod_yaml_with_annotations \
		"${CUSTOM_CA_REGISTRY_IMAGE_REF}" "" "${initdata}" "${node}"
	auto_generate_policy "${policy_settings_dir}" "${kata_pod}"

	k8s_create_pod "${kata_pod}"
	echo "Pod successfully pulled image from custom CA registry"
}

@test "Pull image from custom CA registry fails without extra_root_certificates" {
	local initdata
	initdata=$(get_initdata_with_cdh_image_section "")

	create_coco_pod_yaml_with_annotations \
		"${CUSTOM_CA_REGISTRY_IMAGE_REF}" "" "${initdata}" "${node}"
	auto_generate_policy "${policy_settings_dir}" "${kata_pod}"

	assert_pod_fail "${kata_pod}"
	kubectl describe -f "${kata_pod}" 2>/dev/null \
		| grep -qE "Image Pull error|certificate signed by unknown authority"
}

teardown() {
	if ! is_confidential_runtime_class; then
		skip "Test not supported for ${KATA_HYPERVISOR}."
	fi

	delete_tmp_policy_settings_dir "${policy_settings_dir:-}"
	confidential_teardown_common "${node}" "${node_start_time:-}"
}

teardown_file() {
	if ! is_confidential_runtime_class; then
		return
	fi

	# Stop and remove the test registry.
	${CONTAINER_ENGINE} stop ${CUSTOM_CA_CONTAINER_NAME} 2>/dev/null || true
	${CONTAINER_ENGINE} rm ${CUSTOM_CA_CONTAINER_NAME} 2>/dev/null || true

	# Remove OCP additionalTrustedCA config.
	oc delete configmap ${CUSTOM_CA_CM_NAME} -n openshift-config --ignore-not-found 2>/dev/null || true
	oc patch image.config.openshift.io/cluster --type=merge \
		-p '{"spec":{"additionalTrustedCA":{"name":""}}}' 2>/dev/null || true
}
