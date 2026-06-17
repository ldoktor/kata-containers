#!/usr/bin/env bats
# Copyright (c) 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0
#
# Test LUKS-encrypted block storage for CoCo pods using the Local Storage
# Operator and osc-storage-helper sidecar.

load "${BATS_TEST_DIRNAME}/lib.sh"
load "${BATS_TEST_DIRNAME}/confidential_common.sh"

ENCRYPTED_STORAGE_NS="openshift-local-storage"

setup() {
	is_confidential_runtime_class || skip "Only supported for CoCo"

	kubectl get deployment local-storage-operator \
		-n "${ENCRYPTED_STORAGE_NS}" &>/dev/null || \
		skip "Local Storage Operator not installed"

	setup_common
	get_pod_config_dir

	pod_name="storage-encrypted"
	pvc_name="storage-encrypted"
	local_volume_name="local-disks"
	secret_name="sealed-secrets"
	dev_file="/var/disk-sim"
	loop_dev="/dev/loop1"
	vol_capacity="5Gi"
	OSC_STORAGE_HELPER_IMAGE="${OSC_STORAGE_HELPER_IMAGE:-quay.io/redhat-user-workloads/ose-osc-tenant/osc-storage-helper:latest}"

	# Create loop device on the node
	exec_host "${node}" "dd if=/dev/zero of=${dev_file} bs=1M count=5120 2>/dev/null"
	exec_host "${node}" "losetup ${loop_dev} ${dev_file} 2>/dev/null || true"

	# Create LocalVolume CR
	tmp_lv_yaml=$(mktemp --tmpdir local-volume.XXXXX.yaml)
	sed -e "s|HOSTNAME|${node}|" \
		"${pod_config_dir}/local-volume.yaml" > "${tmp_lv_yaml}"
	kubectl apply -f "${tmp_lv_yaml}"

	# Wait for PV to be created by the operator
	local cmd="kubectl get pv --no-headers 2>/dev/null | grep -q local-sc"
	waitForProcess "${wait_time}" "${sleep_time}" "${cmd}"

	# Create PVC
	kubectl apply -f "${pod_config_dir}/pvc-encrypted-storage.yaml"

	# Create LUKS passphrase secret
	kubectl create secret generic "${secret_name}" \
		--from-literal=secret=test-luks-passphrase 2>/dev/null || true
}

@test "CoCo pod with LUKS-encrypted block storage" {
	sed -e "s|OSC_STORAGE_HELPER_IMAGE|${OSC_STORAGE_HELPER_IMAGE}|" \
		"${pod_config_dir}/pod-encrypted-storage.yaml.in" > "${pod_config_dir}/pod-encrypted-storage.yaml"
	kubectl apply -f "${pod_config_dir}/pod-encrypted-storage.yaml"
	kubectl wait --for=condition=Ready --timeout=300s pod "${pod_name}"

	# Verify I/O through the encrypted mount
	kubectl exec "${pod_name}" -c hello-openshift -- \
		sh -c 'echo "hello encrypted" > /data/test.txt'
	result=$(kubectl exec "${pod_name}" -c hello-openshift -- cat /data/test.txt)
	[[ "${result}" == "hello encrypted" ]]

	# Find the LUKS mapper device
	dm_device=$(kubectl exec "${pod_name}" -c format-disk -- \
		sh -c 'ls /dev/mapper/ | grep -v control' | head -1)
	[[ -n "${dm_device}" ]]

	# Verify encryption settings
	crypt_status=$(kubectl exec "${pod_name}" -c format-disk -- \
		cryptsetup status "/dev/mapper/${dm_device}")
	info "cryptsetup status output:"
	info "${crypt_status}"

	grep -q "is active and is in use" <<< "${crypt_status}"
	grep -Eq "type: +LUKS2" <<< "${crypt_status}"
	grep -Eq "cipher: +aes-xts-plain64" <<< "${crypt_status}"
}

teardown() {
	is_confidential_runtime_class || skip "Only supported for CoCo"

	kubectl delete pod "${pod_name}" --ignore-not-found --timeout=60s || true
	kubectl delete pvc "${pvc_name}" --ignore-not-found --timeout=60s || true
	kubectl delete secret "${secret_name}" --ignore-not-found || true

	# Delete LocalVolume CR (patch finalizer if deletion hangs)
	if kubectl get localvolume "${local_volume_name}" -n "${ENCRYPTED_STORAGE_NS}" &>/dev/null; then
		kubectl delete localvolume "${local_volume_name}" \
			-n "${ENCRYPTED_STORAGE_NS}" --timeout=30s 2>/dev/null || \
		kubectl patch localvolume "${local_volume_name}" \
			-n "${ENCRYPTED_STORAGE_NS}" \
			--type=merge -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
	fi

	kubectl delete storageclass local-sc --ignore-not-found || true

	# Clean up any leftover PV
	local pv_name
	pv_name=$(kubectl get pv -l storage.openshift.io/local-volume-owner-name="${local_volume_name}" \
		-o name 2>/dev/null || true)
	if [[ -n "${pv_name}" ]]; then
		kubectl delete "${pv_name}" --ignore-not-found --timeout=30s 2>/dev/null || \
		kubectl patch "${pv_name}" --type=merge -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
	fi

	# Remove loop device and disk image from the node
	exec_host "${node}" "losetup -d ${loop_dev} 2>/dev/null || true"
	exec_host "${node}" "rm -f ${dev_file}"

	rm -f "${tmp_lv_yaml:-}"

	teardown_common "${node}" "${node_start_time:-}"
}
