#!/usr/bin/env bash

# Copyright (c) 2024 Red Hat
#
# SPDX-License-Identifier: Apache-2.0
#
# Provides a library to deal with the CoCo KBS.
#
# KBS resources can be managed via two backends, selected by KBS_MANAGEMENT:
#   client   - (default) uses kbs-client CLI against the KBS admin API.
#              Used when KBS is deployed directly and the admin API is enabled.
#   operator - uses K8s Secrets + ConfigMaps via the Trustee operator CRDs.
#              Used on OpenShift with Red Hat build of Trustee, where the admin
#              API is disabled and resources are managed declaratively.
#
set -e

kubernetes_dir="${kubernetes_dir:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
# shellcheck disable=1091
source "${kubernetes_dir}/../../gha-run-k8s-common.sh"
# shellcheck disable=1091
source "${kubernetes_dir}/../../../tests/common.bash"
# shellcheck disable=1091
source "${kubernetes_dir}/../../../tools/packaging/guest-image/lib_se.sh"
# For kata-runtime
export PATH="${PATH}:/opt/kata/bin"

KATA_HYPERVISOR="${KATA_HYPERVISOR:-qemu}"
HTTPS_PROXY="${HTTPS_PROXY:-}"
# Where the trustee (includes kbs) sources will be cloned
readonly COCO_TRUSTEE_DIR="/tmp/trustee"
# Where the kbs sources will be cloned
readonly COCO_KBS_DIR="${COCO_TRUSTEE_DIR}/kbs"
# The k8s namespace where the kbs service is deployed
KBS_NS="${KBS_NS:-coco-tenant}"
# The private key file used for CLI authentication
KBS_PRIVATE_KEY="${KBS_PRIVATE_KEY:-/opt/trustee/install/kbs.key}"
# The kbs service name
KBS_SVC_NAME="${KBS_SVC_NAME:-kbs}"
# The kbs ingress name
KBS_INGRESS_NAME="${KBS_INGRESS_NAME:-kbs}"
# Workdir for installing snphost
readonly SNPHOST_DIR="/tmp/snphost-workdir"

# ── High-level policy helpers (shared across backends) ───────────────────────
# These call kbs_set_resources_policy() which is provided by the active backend.

# Set "allow all" policy to resources.
#
kbs_set_allow_all_resources() {
	kbs_set_resources_policy \
		"${COCO_KBS_DIR}/sample_policies/allow_all.rego"
}

kbs_set_default_policy() {
	kbs_set_resources_policy \
		"${COCO_KBS_DIR}/sample_policies/default.rego"
}

# Set "deny all" policy to resources.
#
kbs_set_deny_all_resources() {
	kbs_set_resources_policy \
		"${COCO_KBS_DIR}/sample_policies/deny_all.rego"
}

# Set KBS resource policy requiring GPU0's EAR status to be non-contraindicated.
#
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

# Set KBS resource policy requiring CPU0's EAR status to be affirming.
#
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

# ── Resource helpers (shared across backends) ────────────────────────────────
# These call kbs_set_resource_from_file() which is provided by the active backend.

# Set resource data in base64 encoded.
#
# Parameters:
#	$1 - repository name (optional)
#	$2 - resource type (mandatory)
#	$3 - tag (mandatory)
#	$4 - resource data in base64
#
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

# Set resource data.
#
# Parameters:
#	$1 - repository name (optional)
#	$2 - resource type (mandatory)
#	$3 - tag (mandatory)
#	$4 - resource data
#
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

# ── Service discovery (shared across backends) ──────────────────────────────

# Return the kbs service public IP in case ingress is configured
# otherwise the cluster IP.
#
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
	elif kubectl get svc "${KBS_SVC_NAME}" -n "${KBS_NS}" &>/dev/null; then
			local host
			host=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' -n "${KBS_NS}")
			echo "${host}"
	else
		kubectl get svc "${KBS_SVC_NAME}" -n "${KBS_NS}" \
			-o jsonpath='{.spec.clusterIP}' 2>/dev/null
	fi
}

# Return the kbs service port number.
#
kbs_k8s_svc_port() {
	if kubectl get ingress -n "${KBS_NS}" 2>/dev/null | grep -q kbs; then
		echo "80"
	elif kubectl get svc "${KBS_SVC_NAME}" -n "${KBS_NS}" &>/dev/null; then
		kubectl get svc "${KBS_SVC_NAME}" -n "${KBS_NS}" -o jsonpath='{.spec.ports[0].nodePort}'
	else
		kubectl get svc "${KBS_SVC_NAME}" -n "${KBS_NS}" \
			-o jsonpath='{.spec.ports[0].port}' 2>/dev/null
	fi
}

# Return the kbs service HTTP address (http://host:port).
#
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
}

# ── Shared utilities ────────────────────────────────────────────────────────

# Ensure ~/.cicd/venv exists and activate it in the current shell.
ensure_cicd_python_venv() {
	local venv_path="${HOME}/.cicd/venv"
	if [[ ! -f "${venv_path}/bin/activate" ]]; then
		if command -v pyenv &>/dev/null; then
			export PYENV_ROOT="${HOME}/.pyenv"
			[[ -d "${PYENV_ROOT}/bin" ]] && export PATH="${PYENV_ROOT}/bin:${PATH}"
			eval "$(pyenv init - bash)"
		fi
		mkdir -p "${HOME}/.cicd"
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

ensure_snphost() {
	command -v snphost >/dev/null && return

	git clone https://github.com/virtee/snphost.git "${SNPHOST_DIR}"
	pushd "${SNPHOST_DIR}"

	_ensure_rust "1.85.0"
	cargo build --release
	sudo install -m 755 target/release/snphost /usr/local/bin/

	popd
	rm -rf "${SNPHOST_DIR}"
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

_handle_ingress() {
	local ingress="$1"

	type -a "_handle_ingress_${ingress}" &>/dev/null || {
		echo "ERROR: ingress '${ingress}' handler not implemented";
		return 1;
	}

	"_handle_ingress_${ingress}"
}

_handle_ingress_aks() {
	echo "::group::Enable approuting (application routing) add-on"
	enable_cluster_approuting ""
	echo "::endgroup::"

	pushd "${COCO_KBS_DIR}/config/kubernetes/overlays/"

	echo "::group::$(pwd)/ingress.yaml"
	KBS_INGRESS_CLASS="webapprouting.kubernetes.azure.com" \
		KBS_INGRESS_HOST="\"\"" \
		envsubst < ingress.yaml | tee ingress.yaml.tmp
	echo "::endgroup::"
	mv ingress.yaml.tmp ingress.yaml

	kustomize edit add resource ingress.yaml
	popd
}

_handle_ingress_nodeport() {
	export DEPLOYMENT_DIR=nodeport
}

_post_deploy() {
	local ingress="${1:-}"

	if [[ "${ingress}" = "aks" ]]; then
		echo "Patch the ingress controller to have only one replica of nginx"
		waitForProcess "20" "5" \
			"kubectl patch nginxingresscontroller/default -n app-routing-system --type=merge -p='{\"spec\":{\"scaling\": {\"minReplicas\": 1}}}'"
	fi
}

prepare_credentials_for_qemu_se() {
	echo "::group::Prepare credentials for qemu-se runtime"
	if [[ -z "${IBM_SE_CREDS_DIR:-}" ]]; then
		>&2 echo "ERROR: IBM_SE_CREDS_DIR is empty"
		return 1
	fi
	config_file_path="/opt/kata/share/defaults/kata-containers/configuration-qemu-se.toml"
	kata_base_dir=$(dirname "$(kata-runtime --config "${config_file_path}" env --json | jq -r '.Kernel.Path')")
	if [[ -z "${HKD_PATH:-}" || ! -d "${HKD_PATH}" ]]; then
		>&2 echo "ERROR: HKD_PATH is not set"
		return 1
	fi
	pushd "${IBM_SE_CREDS_DIR}"
	mkdir {certs,crls,hdr,hkds,rsa}
	openssl genrsa -aes256 -passout pass:test1234 -out encrypt_key-psw.pem 4096
	openssl rsa -in encrypt_key-psw.pem -passin pass:test1234 -pubout -out rsa/encrypt_key.pub
	openssl rsa -in encrypt_key-psw.pem -passin pass:test1234 -out rsa/encrypt_key.pem
	cp "${kata_base_dir}/kata-containers-se.img" hdr/hdr.bin
	cp "${HKD_PATH}"/HKD-*.crt hkds/
	cp "${HKD_PATH}/ibm-z-host-key-gen2.crl" crls/
	cp "${HKD_PATH}/DigiCertCA.crt" "${HKD_PATH}/ibm-z-host-key-signing-gen2.crt" certs/
	popd
	ls -R "${IBM_SE_CREDS_DIR}"
	echo "::endgroup::"
}

# ── Load the active backend ─────────────────────────────────────────────────
KBS_MANAGEMENT="${KBS_MANAGEMENT:-client}"
# shellcheck disable=1090
source "${kubernetes_dir}/confidential_kbs_${KBS_MANAGEMENT}.sh"
