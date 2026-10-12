#!/usr/bin/env bats
# Copyright 2024 IBM Corporation
# Copyright 2024 Intel Corporation
#
# SPDX-License-Identifier: Apache-2.0
#

load "${BATS_TEST_DIRNAME}/lib.sh"
load "${BATS_TEST_DIRNAME}/confidential_common.sh"

export KBS="${KBS:-false}"
export test_key="aatest"
export KATA_HYPERVISOR="${KATA_HYPERVISOR:-qemu-runtime-rs}"
export AA_KBC="${AA_KBC:-cc_kbc}"

setup() {
	is_confidential_runtime_class || skip "Test not supported for ${KATA_HYPERVISOR}."

	if [ "${KBS}" = "false" ]; then
		skip "Test skipped as KBS not setup"
	fi

	setup_common || die "setup_common failed"

	# install SNP measurement dependencies
	if [[ "${KATA_HYPERVISOR}" == *snp* ]]; then
		ensure_sev_snp_measure
		ensure_snphost
	fi

#	setup_unencrypted_confidential_pod

	if is_confidential_gpu_hardware; then
		POD_TEMPLATE_BASENAME="pod-attestable-gpu"
	else
		POD_TEMPLATE_BASENAME="pod-attestable"
	fi

	local pod_yaml_in="${pod_config_dir}/${POD_TEMPLATE_BASENAME}.yaml.in"
	export K8S_TEST_YAML="${pod_config_dir}/${POD_TEMPLATE_BASENAME}.yaml"

	# Substitute the runtime class name variable in the YAML template
	RUNTIME_CLASS_NAME="${RUNTIME_CLASS_NAME:-$(get_test_runtime_class)}" \
		envsubst '${RUNTIME_CLASS_NAME}' < "${pod_yaml_in}" > "${K8S_TEST_YAML}"

	# Schedule on a known node so that later it can print the system's logs for
	# debugging.
	set_node "$K8S_TEST_YAML" "$node"

	kbs_set_resource "default" "aa" "key" "$test_key"
	local CC_KBS_ADDR
	export CC_KBS_ADDR=$(kbs_k8s_svc_http_addr)

	if [[ "${COCO_CONFIG_METHOD:-kernel_params}" == "initdata" ]]; then
		local initdata
		initdata=$(generate_attestation_initdata)
		set_metadata_annotation "${K8S_TEST_YAML}" \
			"io.katacontainers.config.hypervisor.cc_init_data" \
			"${initdata}"
	else
		kernel_params_annotation="io.katacontainers.config.hypervisor.kernel_params"
		kernel_params_value="agent.guest_components_rest_api=resource"
		if [ "${AA_KBC}" = "cc_kbc" ]; then
			kernel_params_value+=" agent.aa_kbc_params=cc_kbc::${CC_KBS_ADDR}"
		fi
		set_metadata_annotation "${K8S_TEST_YAML}" \
			"${kernel_params_annotation}" \
			"${kernel_params_value}"
	fi
}

generate_attestation_initdata() {
	local CC_KBS_ADDRESS
	CC_KBS_ADDRESS=$(kbs_k8s_svc_http_addr)

	get_initdata_with_cdh_image_section ""
}

@test "Get CDH resource" {
	if is_confidential_gpu_hardware; then
		kbs_set_gpu0_resource_policy
	elif is_confidential_hardware; then
		kbs_set_default_policy
	else
		kbs_set_allow_all_resources
	fi

	kubectl apply -f "${K8S_TEST_YAML}"

	# Retrieve pod name, wait for it to come up, retrieve pod ip
	export pod_name=$(kubectl get pod -o wide | grep "aa-test-cc" | awk '{print $1;}')

	# Check pod creation
	kubectl wait --for=condition=Ready --timeout="$timeout" pod "${pod_name}"

	# On confidential GPU, CDH fetch and GPU attestation (e.g. remote NRAS)
	# routinely exceed a short fixed sleep after Ready. Poll until both
	# containers have produced the expected output (or timeout).
	if is_confidential_gpu_hardware; then
		waitForProcess "180" "5" "kubectl logs --all-containers=true ${pod_name} 2>/dev/null | grep -q \"${test_key}\""
		waitForProcess "120" "5" "kubectl logs --all-containers=true ${pod_name} 2>/dev/null | grep -iq 'Confidential Compute GPUs Ready state:[[:space:]]*ready'"
	else
		sleep 5
	fi

	kubectl logs --all-containers=true "${pod_name}"
	cmd="kubectl logs --all-containers=true ${pod_name} | grep -q ${test_key}"
	run bash -c "$cmd"
	[ "$status" -eq 0 ]

	if is_confidential_gpu_hardware; then
		cmd="kubectl logs --all-containers=true ${pod_name} | grep -iq 'Confidential Compute GPUs Ready state:[[:space:]]*ready'"
		run bash -c "$cmd"
		[ "$status" -eq 0 ]
	fi
}

@test "Cannot get CDH resource when deny-all policy is set" {
	kbs_set_deny_all_resources
	kubectl apply -f "${K8S_TEST_YAML}"

	# Retrieve pod name, wait for it to come up, retrieve pod ip
	export pod_name=$(kubectl get pod -o wide | grep "aa-test-cc" | awk '{print $1;}')

	# Check pod creation
	kubectl wait --for=condition=Ready --timeout="$timeout" pod "${pod_name}"

	sleep 5

	kubectl logs --all-containers=true "${pod_name}"
	cmd="kubectl logs --all-containers=true ${pod_name} | grep -q ${test_key}"
	run bash -c "$cmd"
	[ "$status" -eq 1 ]
}

# Negative test for getting a resource when the affirming policy is set
# (the AS policy must return an affirming trust vector), but no
# reference values are set.
#
# Skipped on IBM SEL / qemu-se* because that environment returns an
# affirming trust vector when verification completes successfully, even
# without reference values.
#
# Also skipped for non-SNP runtimes with operator-managed KBS (e.g. Red Hat build of Trustee)
# where the built-in AS verifies TDX evidence against Intel collateral
# from PCCS and produces affirming trust claims without explicit
# reference values — same behavior as IBM SEL.
@test "Cannot get CDH resource when affirming policy is set without reference values" {

	if [[ "${KATA_HYPERVISOR}" == qemu-se* ]]; then
		local skip_reason="IBM SEL returns an affirming trust vector if the verification process "
		skip_reason+="completes successfully, even if no reference values are set. See "
		skip_reason+="https://github.com/confidential-containers/trustee/blob/d4e317620c4039c89779b725f74974d8f005da66/attestation-service/src/ear_token/ear_default_policy_cpu.rego#L323-L339"
		skip "${skip_reason}"
	fi

	if [[ "${KBS_MANAGEMENT:-client}" == "operator" && "${KATA_HYPERVISOR}" != *snp* ]]; then
		skip "Operator-managed AS produces affirming trust claims from PCCS collateral without explicit reference values"
	fi

	# Require CPU0 to have affirming trust level.
	kbs_set_cpu0_resource_policy
	kubectl apply -f "${K8S_TEST_YAML}"

	# Retrieve pod name, wait for it to come up, retrieve pod ip
	export pod_name=$(kubectl get pod -o wide | grep "aa-test-cc" | awk '{print $1;}')

	# Check pod creation
	kubectl wait --for=condition=Ready --timeout="$timeout" pod "${pod_name}"

	sleep 5

	kubectl logs --all-containers=true "${pod_name}"
	cmd="kubectl logs --all-containers=true ${pod_name} | grep -q ${test_key}"
	run bash -c "$cmd"
	[ "$status" -eq 1 ]
}

@test "Can get CDH resource when affirming policy is set with reference values" {

	[[ "${KATA_HYPERVISOR}" == *snp* ]] || skip "Test only supported with SNP"

	# Bootstrap the exact same guest under allow-all. This also lets the test
	# run on its own, without measuring a guest left by a previous test.
	kbs_set_allow_all_resources
	local bootstrap_start
	bootstrap_start=$(measure_node_time "${node}")
	kubectl apply -f "${K8S_TEST_YAML}"
	kubectl wait --for=condition=Ready --timeout="$timeout" pod aa-test-cc
	kbs_set_snp_reference_values "${bootstrap_start}"

	kubectl delete pod aa-test-cc --wait=true
	kbs_set_cpu0_resource_policy
	kubectl apply -f "${K8S_TEST_YAML}"

	# Retrieve pod name, wait for it to come up, retrieve pod ip
	export pod_name=$(kubectl get pod -o wide | grep "aa-test-cc" | awk '{print $1;}')

	# Check pod creation
	kubectl wait --for=condition=Ready --timeout="$timeout" pod "${pod_name}"

	# Same as "Get CDH resource": on confidential GPU, CDH fetch and GPU attestation
	# can exceed a short fixed sleep after Ready.
	if is_confidential_gpu_hardware; then
		waitForProcess "180" "5" "kubectl logs --all-containers=true ${pod_name} 2>/dev/null | grep -q \"${test_key}\""
		waitForProcess "120" "5" "kubectl logs --all-containers=true ${pod_name} 2>/dev/null | grep -iq 'Confidential Compute GPUs Ready state:[[:space:]]*ready'"
	else
		sleep 5
	fi

	kubectl logs --all-containers=true "${pod_name}"
	cmd="kubectl logs --all-containers=true ${pod_name} | grep -q ${test_key}"
	run bash -c "$cmd"
	[ "$status" -eq 0 ]
}


teardown() {
	is_confidential_runtime_class || skip "Test not supported for ${KATA_HYPERVISOR}."

	if [ "${KBS}" = "false" ]; then
		skip "Test skipped as KBS not setup"
	fi

	if [[ "${KATA_HYPERVISOR}" == *snp* ]]; then
		kbs_snp_cleanup
	fi

	confidential_teardown_common "${node}" "${node_start_time:-}"
}
