#!/usr/bin/env bash
#
# Copyright (c) 2024 Red Hat
#
# SPDX-License-Identifier: Apache-2.0
#
# KBS management backend using kbs-client CLI.
# Used when KBS is deployed directly (not via an operator) and the admin API
# is available. This is the default backend (KBS_MANAGEMENT=client).
#

# Set resources policy.
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

	kbs-client --url "${KBS_CLIENT_URL:-$(kbs_k8s_svc_http_addr)}" config \
		--auth-private-key "${KBS_PRIVATE_KEY}" set-resource-policy \
		--policy-file "${file}"
}

# Execute an admin command via the KBS client using the correct
# URI and admin authentication key.
#
# Parameters:
#	$@ - config subcommand and arguments
#
kbs_config_command() {
	kbs-client --url "${KBS_CLIENT_URL:-$(kbs_k8s_svc_http_addr)}" config \
                --auth-private-key "${KBS_PRIVATE_KEY}" "$@"
}

# Set resource, read data from file.
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

	local path=""
	[[ -n "${repository}" ]] && path+="${repository}/"
	path+="${type}/"
	path+="${tag}"

	kbs-client --url "${KBS_CLIENT_URL:-$(kbs_k8s_svc_http_addr)}" config \
		--auth-private-key "${KBS_PRIVATE_KEY}" set-resource \
		--path "${path}" --resource-file "${file}"
}

# Build and install the kbs-client binary, unless it is already present.
#
kbs_install_cli() {
	command -v kbs-client >/dev/null && return

	source /etc/os-release || source /usr/lib/os-release
	case "${ID}" in
		debian|ubuntu)
			local pkgs="build-essential pkg-config libssl-dev"

			sudo apt-get update -y
			# shellcheck disable=2086
			sudo apt-get install -y ${pkgs}
			;;
		centos)
			local pkgs="make"

			# shellcheck disable=2086,2248
			sudo dnf install -y ${pkgs}
			;;
		*)
			>&2 echo "ERROR: running on unsupported distro"
			return 1
			;;
	esac

	# Mininum required version to build the client (read from versions.yaml)
	local rust_version
	ensure_yq
	rust_version=$(get_from_kata_deps ".externals.coco-trustee.toolchain")
	_ensure_rust "${rust_version}"

	pushd "${COCO_KBS_DIR}"
	make CLI_FEATURES=sample_only cli
	sudo make install-cli
	popd
}

kbs_uninstall_cli() {
	if [[ -d "${COCO_KBS_DIR}" ]]; then
		pushd "${COCO_KBS_DIR}"
		sudo make uninstall
		popd
	else
		echo "${COCO_KBS_DIR} does not exist in the machine, skip uninstalling the kbs cli"
	fi
}

# Deploy the kbs on Kubernetes
#
# Parameters:
#	$1 - apply the specified ingress handler to expose the service externally
#
function kbs_k8s_deploy() {
	local image
	local image_tag
	local ingress=${1:-}
	local repo
	local svc_host
	local timeout
	local kbs_ip
	local kbs_port
	local version

	ensure_yq

	repo=$(get_from_kata_deps ".externals.coco-trustee.url")
	version=$(get_from_kata_deps ".externals.coco-trustee.version")
	image=$(get_from_kata_deps ".externals.coco-trustee.image")
	image_tag=$(get_from_kata_deps ".externals.coco-trustee.image_tag")

	if [[ -z "${AKS_NAME:-}" ]]; then
		AKS_NAME=$(_print_cluster_name)
		export AKS_NAME
	fi

	if [[ -d "${COCO_TRUSTEE_DIR}" ]]; then
		rm -rf "${COCO_TRUSTEE_DIR}"
	fi

	echo "::group::Clone the kbs sources"
	git clone --depth 1 "${repo}" "${COCO_TRUSTEE_DIR}"
	pushd "${COCO_TRUSTEE_DIR}"
	git fetch --depth=1 origin "${version}"
	git checkout FETCH_HEAD -b kbs_$$
	popd
	echo "::endgroup::"

	pushd "${COCO_KBS_DIR}/config/kubernetes/"

	echo "somesecret" > overlays/key.bin

	if [[ "${KATA_HYPERVISOR}" == qemu-se* ]]; then
		mv overlays/key.bin overlays/ibm-se/key.bin
		prepare_credentials_for_qemu_se
		sed -i "s/false/true/g" overlays/ibm-se/patch.yaml
	fi

	echo "::group::Update the kbs container image"
	install_kustomize
	pushd base
	kustomize edit set image "kbs-container-image=${image}:${image_tag}"
	popd
	echo "::endgroup::"
	[[ -n "${ingress}" ]] && _handle_ingress "${ingress}"

	echo "::group::Deploy the KBS"
	if [[ "${KATA_HYPERVISOR}" = "qemu-tdx" ]]; then
		if [[ -n "${HTTPS_PROXY}" ]]; then
			pushd "${COCO_KBS_DIR}/config/kubernetes/base/"
				ensure_yq
				yq e ".spec.template.spec.containers[0].env += [{\"name\": \"https_proxy\", \"value\": \"${HTTPS_PROXY}\"}]" -i deployment.yaml
			popd
		fi
	fi

	./deploy-kbs.sh

	local install_key="${PWD}/base/kbs.key"
	if [[ ! -f "${install_key}" ]]; then
		echo "ERROR: KBS private key not found at ${install_key}"
		return 1
	fi
	sudo mkdir -p "$(dirname "${KBS_PRIVATE_KEY}")"
	sudo cp -f "${install_key}" "${KBS_PRIVATE_KEY}"

	popd

	if ! waitForProcess "120" "10" "kubectl -n \"${KBS_NS}\" get pods | \
		grep -q '^kbs-.*Running.*'"; then
		echo "ERROR: KBS service pod isn't running"
		echo "::group::DEBUG - describe kbs deployments"
		kubectl -n "${KBS_NS}" get deployments || true
		echo "::endgroup::"
		echo "::group::DEBUG - describe kbs pod"
		kubectl -n "${KBS_NS}" describe pod -l app=kbs || true
		echo "::endgroup::"
		echo "::group::DEBUG - kbs logs"
		kubectl -n "${KBS_NS}" logs -l app=kbs || true
		echo "::endgroup::"
		return 1
	fi
	echo "::endgroup::"

	echo "::group::Post deploy actions"
	_post_deploy "${ingress}"
	echo "::endgroup::"

	echo "::group::Check the service healthy"
	kbs_ip=$(kubectl get -o jsonpath='{.spec.clusterIP}' svc "${KBS_SVC_NAME}" -n "${KBS_NS}" 2>/dev/null)
	kbs_port=$(kubectl get -o jsonpath='{.spec.ports[0].port}' svc "${KBS_SVC_NAME}" -n "${KBS_NS}" 2>/dev/null)

	local pod=kbs-checker-$$
	kubectl run "${pod}" --image=quay.io/prometheus/busybox --restart=Never -- \
		sh -c "wget -O- --timeout=60 \"${kbs_ip}:${kbs_port}\" || true"
	if ! waitForProcess "60" "10" "kubectl logs \"${pod}\" 2>/dev/null | grep -q \"404 Not Found\""; then
		echo "ERROR: KBS service is not responding to requests"
		echo "::group::DEBUG - kbs logs"
		kubectl -n "${KBS_NS}" logs -l app=kbs || true
		echo "::endgroup::"
		kubectl delete pod "${pod}"
		return 1
	fi
	kubectl delete pod "${pod}"
	echo "KBS service respond to requests"
	echo "::endgroup::"

	if [[ -n "${ingress}" ]]; then
		echo "::group::Check the kbs service is exposed"
		svc_host=$(kbs_k8s_svc_http_addr)
		if [[ -z "${svc_host}" ]]; then
			echo "ERROR: service host not found"
			return 1
		fi

		timeout=350
		echo "Trying to connect at ${svc_host}. Timeout=${timeout}"
		if ! waitForProcess "${timeout}" "30" "curl -s -I \"${svc_host}\" | grep -q \"404 Not Found\""; then
			echo "ERROR: service seems to not respond on ${svc_host} host"
			curl -I "${svc_host}"
			return 1
		fi
		echo "KBS service respond to requests at ${svc_host}"
		echo "::endgroup::"
	fi
}

# Delete the kbs on Kubernetes
#
function kbs_k8s_delete() {
	pushd "${COCO_KBS_DIR}"
	if [[ "${KATA_HYPERVISOR}" = qemu-se* ]]; then
		kubectl delete -k config/kubernetes/overlays/ibm-se
	else
		kubectl delete -k config/kubernetes/overlays/
	fi

	cmd="kubectl get all -n ${KBS_NS} 2>&1 | grep 'No resources found'"
	waitForProcess "120" "30" "${cmd}"
	popd
}
