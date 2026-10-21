#!/usr/bin/env bash

# Copyright (c) 2024 Red Hat
#
# SPDX-License-Identifier: Apache-2.0
#
# Provides a library to deal with the CoCo KBS.
# KBS_MANAGEMENT selects the client (default) or operator backend.
#
set -e

kubernetes_dir="${kubernetes_dir:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
# shellcheck disable=1091
source "${kubernetes_dir}/../../gha-run-k8s-common.sh"
# shellcheck disable=1091
source "${kubernetes_dir}/../../../tests/common.bash"
# shellcheck disable=1091
source "${kubernetes_dir}/../../../tools/packaging/guest-image/lib_se.sh"
export PATH="${PATH}:/opt/kata/bin"

KATA_HYPERVISOR="${KATA_HYPERVISOR:-qemu-runtime-rs}"
HTTPS_PROXY="${HTTPS_PROXY:-${https_proxy:-}}"
# Where the trustee (includes kbs) sources will be cloned
readonly COCO_TRUSTEE_DIR="${COCO_TRUSTEE_DIR:-/tmp/trustee}"
# Where the kbs sources will be cloned
readonly COCO_KBS_DIR="${COCO_TRUSTEE_DIR}/kbs"

KBS_MANAGEMENT="${KBS_MANAGEMENT:-client}"
if [[ "${KBS_MANAGEMENT}" == "operator" ]]; then
	KBS_NS="${KBS_NS:-coco-tenant}"
	KBS_SVC_NAME="${KBS_SVC_NAME:-kbs}"
	KBS_INGRESS_NAME="${KBS_INGRESS_NAME:-kbs}"
else
	KBS_NS="${KBS_NS:-coco-trustee}"
	KBS_SVC_NAME="${KBS_SVC_NAME:-trustee-kbs}"
	KBS_INGRESS_NAME="${KBS_INGRESS_NAME:-trustee-kbs}"
fi
KBS_NODEPORT_SVC_NAME="${KBS_NODEPORT_SVC_NAME:-${KBS_SVC_NAME}-nodeport}"

# These policies are applied through the active backend.
kbs_set_allow_all_resources() {
	kbs_set_resources_policy \
		"${COCO_KBS_DIR}/sample_policies/allow_all.rego"
}

kbs_set_default_policy() {
	kbs_set_resources_policy \
		"${COCO_KBS_DIR}/sample_policies/default.rego"
}

kbs_set_deny_all_resources() {
	kbs_set_resources_policy \
		"${COCO_KBS_DIR}/sample_policies/deny_all.rego"
}

kbs_set_gpu0_resource_policy() {
	local policy_file
	policy_file=$(mktemp -t kbs-gpu-policy-XXXXX.rego)

	cat > "${policy_file}" <<-'EOF'
		package policy
		import rego.v1
		default allow = false
		allow if {
		    input["submods"]["gpu0"]["ear.status"] == "affirming"
		}
	EOF

	kbs_set_resources_policy "${policy_file}"
	local rc=$?
	rm -f "${policy_file}"
	return "${rc}"
}

kbs_set_cpu0_resource_policy() {
	local policy_file
	policy_file=$(mktemp -t kbs-cpu-policy-XXXXX.rego)

	cat > "${policy_file}" <<-'EOF'
		package policy
		import rego.v1
		default allow = false
		allow if {
		    input["submods"]["cpu0"]["ear.status"] == "affirming"
		}
	EOF

	kbs_set_resources_policy "${policy_file}"
	local rc=$?
	rm -f "${policy_file}"
	return "${rc}"
}

# Parameters: repository (optional), type, tag, base64-encoded data.
kbs_set_resource_base64() {
	local repository="${1:-}"
	local type="${2:-}"
	local tag="${3:-}"
	local data="${4:-}"
	local file
	local rc=0

	if [[ -z "${data}" ]]; then
		>&2 echo "ERROR: missing data parameter"
		return 1
	fi

	file=$(mktemp -t kbs-resource-XXXXX)
	echo "${data}" | base64 -d > "${file}"

	kbs_set_resource_from_file "${repository}" "${type}" "${tag}" "${file}" || \
		rc=$?

	rm -f "${file}"
	return "${rc}"
}

# Parameters: repository (optional), type, tag, data.
kbs_set_resource() {
	local repository="${1:-}"
	local type="${2:-}"
	local tag="${3:-}"
	local data="${4:-}"
	local file
	local rc=0

	if [[ -z "${data}" ]]; then
		>&2 echo "ERROR: missing data parameter"
		return 1
	fi

	file=$(mktemp -t kbs-resource-XXXXX)
	echo "${data}" > "${file}"

	kbs_set_resource_from_file "${repository}" "${type}" "${tag}" "${file}" || \
		rc=$?

	rm -f "${file}"
	return "${rc}"
}

# Return the ingress IP, NodePort host, or cluster IP.
kbs_k8s_svc_host() {
	if kubectl get ingress -n "${KBS_NS}" 2>/dev/null | grep -q kbs; then
		local host
		local timeout=50
		SECONDS=0
		while true; do
			host=$(kubectl get ingress "${KBS_INGRESS_NAME}" -n "${KBS_NS}" -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
			[[ -z "${host}" && ${SECONDS} -lt "${timeout}" ]] || break
			sleep 5
		done
		echo "${host}"
	elif kubectl get svc "${KBS_NODEPORT_SVC_NAME}" -n "${KBS_NS}" &>/dev/null; then
		local host
		host=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
		echo "${host}"
	else
		kubectl get svc "${KBS_SVC_NAME}" -n "${KBS_NS}" \
			-o jsonpath='{.spec.clusterIP}' 2>/dev/null
	fi
}

kbs_k8s_svc_port() {
	if kubectl get ingress -n "${KBS_NS}" 2>/dev/null | grep -q kbs; then
		echo "80"
	elif kubectl get svc "${KBS_NODEPORT_SVC_NAME}" -n "${KBS_NS}" &>/dev/null; then
		kubectl get svc "${KBS_NODEPORT_SVC_NAME}" -n "${KBS_NS}" -o jsonpath='{.spec.ports[0].nodePort}'
	else
		kubectl get svc "${KBS_SVC_NAME}" -n "${KBS_NS}" \
			-o jsonpath='{.spec.ports[0].port}' 2>/dev/null
	fi
}

kbs_k8s_svc_http_addr() {
	local host
	local port
	host=$(kbs_k8s_svc_host)
	port=$(kbs_k8s_svc_port)
	echo "http://${host}:${port}"
}

kbs_k8s_print_logs() {
	local start_time="$1"
	local iso_start_time
	iso_start_time=$(date -d "${start_time}" --iso-8601=seconds)

	echo "::group::DEBUG - kbs logs since ${start_time}"
	kubectl -n "${KBS_NS}" logs -l app=kbs --since-time="${iso_start_time}" --timestamps=true || true
	echo "::endgroup::"
	echo "::group::DEBUG - as logs since ${start_time}"
	kubectl -n "${KBS_NS}" logs -l app=attestation-service --since-time="${iso_start_time}" --timestamps=true || true
	echo "::endgroup::"
	echo "::group::DEBUG - rvps logs since ${start_time}"
	kubectl -n "${KBS_NS}" logs -l app=reference-value-provider-service --since-time="${iso_start_time}" --timestamps=true || true
	echo "::endgroup::"
}

# Callers with incompatible dependencies can select a separate virtualenv.
ensure_cicd_python_venv() {
	local venv_path="${1:-${HOME}/.cicd/venv}"
	if [[ ! -f "${venv_path}/bin/activate" ]]; then
		if command -v pyenv &>/dev/null; then
			export PYENV_ROOT="${HOME}/.pyenv"
			[[ -d "${PYENV_ROOT}/bin" ]] && export PATH="${PYENV_ROOT}/bin:${PATH}"
			eval "$(pyenv init - bash)"
		fi
		mkdir -p "$(dirname "${venv_path}")"
		python3 -m venv "${venv_path}"
	fi
	# shellcheck disable=SC1091
	source "${venv_path}/bin/activate"
}

ensure_sev_snp_measure() {
	command -v sev-snp-measure >/dev/null && return
	ensure_cicd_python_venv
	pip install sev-snp-measure
}

# Register SNP reference values from a guest launched since the given node time.
# Backends provide host execution/file access, snphost deployment and reference
# value preparation/cleanup; parsing and measurement stay shared here.
kbs_set_snp_reference_values() {
	local start_time="$1"
	kbs_prepare_snp_reference_values

	local journal log_line qemu_cmd
	journal=$(kbs_host_exec journalctl --no-pager -r -x -t kata --since "${start_time}")
	# Go runtime logs: "launching <path> with: [<args>]"
	# runtime-rs logs: "qemu args: <args>"
	log_line=$(echo "${journal}" | grep -m 1 'launching.*qemu.*with:' || true)
	if [[ -n "${log_line}" ]]; then
		qemu_cmd=$(echo "${log_line}" | sed 's/.*with: \[\(.*\)\]".*/\1/')
	else
		log_line=$(echo "${journal}" | grep -m 1 'qemu args:' || true)
		qemu_cmd=$(echo "${log_line}" | sed 's/.*qemu args: //')
	fi
	[[ -n "${qemu_cmd}" ]] || { echo "Could not find QEMU command line"; return 1; }

	local kernel_path initrd_path firmware_path vcpu_count append
	kernel_path=$(echo "${qemu_cmd}" | grep -oP -- '-kernel \K[^ ]+')
	initrd_path=$(echo "${qemu_cmd}" | grep -oP -- '-initrd \K[^ ]+' || true)
	firmware_path=$(echo "${qemu_cmd}" | grep -oP -- '-bios \K[^ ]+')
	vcpu_count=$(echo "${qemu_cmd}" | grep -oP -- '-smp \K\d+')
	append=$(echo "${qemu_cmd}" | grep -oP -- '-append \K.*?(?= -(smp|bios) )')
	# Remove escape backslashes from dm-mod.create parameters.
	append="${append//\\\"/\"}"

	# Measurement is local for both backends and needs no SNP hardware.
	kbs_copy_host_file "${kernel_path}" "${BATS_TEST_TMPDIR}/kernel"
	kbs_copy_host_file "${firmware_path}" "${BATS_TEST_TMPDIR}/ovmf"
	local measure_args=(
		--mode=snp
		--vcpus="${vcpu_count}"
		--vcpu-type=EPYC-v4
		--output-format=hex
		--ovmf="${BATS_TEST_TMPDIR}/ovmf"
		--kernel="${BATS_TEST_TMPDIR}/kernel"
		--append="${append}"
	)
	if [[ -n "${initrd_path}" ]]; then
		kbs_copy_host_file "${initrd_path}" "${BATS_TEST_TMPDIR}/initrd"
		measure_args+=(--initrd="${BATS_TEST_TMPDIR}/initrd")
	fi
	local launch_measurement firmware
	launch_measurement=$(PATH="${PATH}:${HOME}/.local/bin" sev-snp-measure "${measure_args[@]}")
	echo "Calculated SNP launch measurement: ${launch_measurement}"
	kbs_config_command set-sample-reference-value snp_launch_measurement "${launch_measurement}"

	firmware=$(kbs_host_exec "${SNPHOST_BINARY}" show tcb | grep -A 5 "Reported TCB")
	local microcode_version snp_version tee_version bootloader_version
	microcode_version=$(echo "${firmware}" | grep -oP 'Microcode:\s*\K\d+')
	snp_version=$(echo "${firmware}" | grep -oP 'SNP:\s*\K\d+')
	tee_version=$(echo "${firmware}" | grep -oP 'TEE:\s*\K\d+')
	bootloader_version=$(echo "${firmware}" | grep -oP 'Boot Loader:\s*\K\d+')
	kbs_config_command set-sample-reference-value --as-integer snp_bootloader "${bootloader_version}"
	kbs_config_command set-sample-reference-value --as-integer snp_microcode "${microcode_version}"
	kbs_config_command set-sample-reference-value --as-integer snp_snp_svn "${snp_version}"
	kbs_config_command set-sample-reference-value --as-integer snp_tee_svn "${tee_version}"
}

_ensure_rust() {
	rust_version=${1:-}
	if ! command -v rustc >/dev/null; then
		"${kubernetes_dir}/../../install_rust.sh" "${rust_version}"
		# shellcheck disable=1091
		source "${HOME}/.cargo/env"
	else
		[[ -z "${rust_version}" ]] && return
		local current_rust_version
		current_rust_version="$(rustc --version | cut -d' ' -f2)"
		if ! version_greater_than_equal "${current_rust_version}" \
			"${rust_version}"; then
			>&2 echo "ERROR: installed rust ${current_rust_version} < ${rust_version} (required)"
			return 1
		fi
	fi
}

# shellcheck disable=1090
source "${kubernetes_dir}/confidential_kbs_${KBS_MANAGEMENT}.sh"
