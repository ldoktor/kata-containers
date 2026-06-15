#!/usr/bin/env bats
#
# Copyright (c) 2026 Red Hat, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#
# Test that the default_memory hypervisor annotation controls the
# guest VM memory allocation.

load "${BATS_TEST_DIRNAME}/../../common.bash"
load "${BATS_TEST_DIRNAME}/lib.sh"
load "${BATS_TEST_DIRNAME}/tests_common.sh"

setup() {
	is_firecracker_hypervisor "${KATA_HYPERVISOR}" && \
		skip "Firecracker doesn't support memory annotation override"

	setup_common || die "setup_common failed"

	pod_name="test-e2e"
	test_memory_mb=2048

	policy_settings_dir="$(create_tmp_policy_settings_dir "${pod_config_dir}")"
}

@test "Check default_memory annotation sets guest memory" {
	local pod_config
	pod_config=$(new_pod_config "quay.io/prometheus/busybox:latest" \
		"$(get_test_runtime_class)")
	set_container_command "${pod_config}" "0" "sleep" "120"
	set_metadata_annotation "${pod_config}" \
		"io.katacontainers.config.hypervisor.default_memory" "${test_memory_mb}"
	set_node "${pod_config}" "${node}"
	auto_generate_policy "${policy_settings_dir}" "${pod_config}"

	kubectl apply -f "${pod_config}"
	kubectl wait --for=condition=Ready --timeout="${timeout}" pod "${pod_name}"

	local guest_mem_kb
	guest_mem_kb=$(kubectl exec "${pod_name}" -- \
		awk '/MemTotal/{print $2}' /proc/meminfo)
	info "Guest MemTotal: ${guest_mem_kb} kB (expected ~$((test_memory_mb * 1024)) kB)"

	local expected_kb=$((test_memory_mb * 1024))
	# TDX reserves additional memory for metadata, allow 15% overhead
	(( guest_mem_kb >= expected_kb * 85 / 100 ))
}

teardown() {
	kubectl delete pod "${pod_name}" --ignore-not-found 2>/dev/null || true

	delete_tmp_policy_settings_dir "${policy_settings_dir:-}"
	teardown_common "${node}" "${node_start_time:-}"
}
