#!/usr/bin/env bats
# Copyright 2022-2023 Advanced Micro Devices, Inc.
# Copyright 2023 Intel Corporation
#
# SPDX-License-Identifier: Apache-2.0
#

load "${BATS_TEST_DIRNAME}/lib.sh"
load "${BATS_TEST_DIRNAME}/../../common.bash"
load "${BATS_TEST_DIRNAME}/confidential_common.sh"
load "${BATS_TEST_DIRNAME}/tests_common.sh"

export KATA_HYPERVISOR="${KATA_HYPERVISOR:-qemu}"
export RUNTIME_CLASS_NAME="${RUNTIME_CLASS_NAME:-kata-${KATA_HYPERVISOR}}"

# COCO_VERIFY_METHOD controls how the TEE status is checked inside the pod.
#   ssh  - (default) SSH into the pod using its cluster IP.
#   exec - use kubectl exec (for environments without direct pod network access).
COCO_VERIFY_METHOD="${COCO_VERIFY_METHOD:-ssh}"

setup() {
	if ! is_confidential_hardware; then
		skip "Test is supported only on confidential hardware (which ${KATA_HYPERVISOR} is not)"
	fi
	setup_common || die "setup_common failed"
	setup_unencrypted_confidential_pod
}

@test "Test unencrypted confidential container launch success and verify that we are running in a secure enclave." {
	# Start the service/deployment/pod
	kubectl apply -f "${pod_config_dir}/pod-confidential-unencrypted.yaml"

	# Retrieve pod name, wait for it to come up, retrieve pod ip
	pod_name=$(kubectl get pod -o wide | grep "confidential-unencrypted" | awk '{print $1;}')

	# Check pod creation
	kubectl wait --for=condition=Ready --timeout=$timeout pod "${pod_name}"

	local verify_cmd
	verify_cmd="$(get_remote_command_per_hypervisor)"
	[ -n "${verify_cmd}" ] || die "No TEE verification command for ${KATA_HYPERVISOR}"

	coco_enabled=""
	if [[ "${COCO_VERIFY_METHOD}" == "exec" ]]; then
		for i in {1..6}; do
			coco_enabled=$(kubectl exec "${pod_name}" -- bash -c "${verify_cmd}" 2>/dev/null) && break
			warn "kubectl exec attempt ${i} failed, retrying..."
			sleep 5
		done
	else
		for i in {1..6}; do
			rm -f "${HOME}/.ssh/known_hosts"
			if ! pod_ip=$(kubectl get pod -o wide | grep "confidential-unencrypted" | awk '{print $6;}'); then
				warn "Failed to get pod IP address."
			else
				info "Pod IP address: ${pod_ip}"
				coco_enabled=$(ssh -i ${SSH_KEY_FILE} -o "StrictHostKeyChecking no" -o "PasswordAuthentication=no" root@${pod_ip} "${verify_cmd}" 2> /dev/null) && break
				warn "Failed to connect to pod."
			fi
			sleep 5
		done
	fi
	[ -z "$coco_enabled" ] && die "Confidential compute is expected but not enabled."
	info "TEE verification output (${COCO_VERIFY_METHOD}): ${coco_enabled}"
}

teardown() {
	if ! is_confidential_hardware; then
		skip "Test is supported only on confidential hardware (which ${KATA_HYPERVISOR} is not)"
	fi

	kubectl describe "pod/${pod_name}" || true
	kubectl delete -f "${pod_config_dir}/pod-confidential-unencrypted.yaml" || true
	teardown_common "${node}" "${node_start_time:-}"
}
