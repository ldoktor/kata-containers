#!/bin/bash
# Copyright (c) 2026 Red Hat, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#
# Generate a signed vault sealed secret and signing key pair using
# coco-tool. Exports SEALED_SECRET_PRECREATED_TEST and
# SEALED_SECRET_SIGNING_PUBLIC_JWK so k8s-sealed-secret.bats uses
# dynamically generated values instead of pre-baked constants.

COCO_TOOLS_IMAGE="${COCO_TOOLS_IMAGE:-quay.io/openshift_sandboxed_containers/coco-tools:0.5.0-rc2}"
CONTAINER_ENGINE="${CONTAINER_ENGINE:-docker}"

generate_sealed_secret() {
	local resource_uri="${1:-kbs:///default/sealed-secret/test}"
	local signing_kid="${2:-kbs:///default/signing-key/sealed-secret}"
	local tmpdir
	tmpdir=$(mktemp -d /tmp/sealed-secret.XXXXXX)

	echo "=== Generating signed sealed secret via coco-tool ==="

	# Generate EC P-256 key pair with openssl and convert to JWK.
	openssl ecparam -name prime256v1 -genkey -noout \
		-out "${tmpdir}/key.pem" 2>/dev/null
	local key_text
	key_text=$(openssl ec -in "${tmpdir}/key.pem" -text -noout 2>/dev/null)

	local priv_hex pub_hex x_hex y_hex
	priv_hex=$(echo "$key_text" | sed -n '/priv:/,/pub:/p' \
		| grep -oE '[0-9a-f]{2}(:[0-9a-f]{2})*' | tr -d ':\n')
	pub_hex=$(echo "$key_text" | sed -n '/pub:/,/ASN1/p' \
		| grep -oE '[0-9a-f]{2}(:[0-9a-f]{2})*' | tr -d ':\n')
	x_hex=${pub_hex:2:64}
	y_hex=${pub_hex:66:64}

	_hex_to_b64url() {
		echo -n "$1" | xxd -r -p | base64 -w0 | tr '+/' '-_' | tr -d '='
	}

	local x_b64 y_b64 d_b64
	x_b64=$(_hex_to_b64url "$x_hex")
	y_b64=$(_hex_to_b64url "$y_hex")
	d_b64=$(_hex_to_b64url "$priv_hex")

	local private_jwk public_jwk
	private_jwk="{\"kty\":\"EC\",\"crv\":\"P-256\",\"alg\":\"ES256\",\"use\":\"sig\",\"kid\":\"${signing_kid}\",\"x\":\"${x_b64}\",\"y\":\"${y_b64}\",\"d\":\"${d_b64}\"}"
	public_jwk="{\"kty\":\"EC\",\"crv\":\"P-256\",\"alg\":\"ES256\",\"use\":\"sig\",\"kid\":\"${signing_kid}\",\"x\":\"${x_b64}\",\"y\":\"${y_b64}\"}"

	echo "${private_jwk}" > "${tmpdir}/private.jwk"

	# Seal the secret with coco-tool.
	local volume_opts=":ro"
	if [[ "${CONTAINER_ENGINE}" == "podman" ]]; then
		volume_opts=":Z,ro"
	fi

	local sealed
	sealed=$(${CONTAINER_ENGINE} run --rm \
		-v "${tmpdir}/private.jwk:/keys/private.jwk${volume_opts}" \
		"${COCO_TOOLS_IMAGE}" \
		/tools/secret seal \
		--signing-kid "${signing_kid}" \
		--signing-jwk-path /keys/private.jwk \
		vault \
		--resource-uri "${resource_uri}" \
		--provider kbs 2>/dev/null | grep '^sealed\.')

	rm -rf "${tmpdir}"

	export SEALED_SECRET_PRECREATED_TEST="${sealed}"
	export SEALED_SECRET_SIGNING_PUBLIC_JWK="${public_jwk}"

	echo "  SEALED_SECRET_PRECREATED_TEST=${SEALED_SECRET_PRECREATED_TEST:0:80}..."
	echo "  SEALED_SECRET_SIGNING_PUBLIC_JWK=${SEALED_SECRET_SIGNING_PUBLIC_JWK:0:80}..."
}
