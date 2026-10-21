#!/usr/bin/env bats
# Copyright (c) 2024 IBM Corporation
# Copyright (c) 2024 Alibaba Corporation
#
# SPDX-License-Identifier: Apache-2.0
#

load "${BATS_TEST_DIRNAME}/lib.sh"
load "${BATS_TEST_DIRNAME}/confidential_common.sh"

export KBS="${KBS:-false}"
export SNAPSHOTTER="${SNAPSHOTTER:-}"
export EXPERIMENTAL_FORCE_GUEST_PULL="${EXPERIMENTAL_FORCE_GUEST_PULL:-}"

setup() {
    if ! is_confidential_runtime_class; then
        skip "Test not supported for ${KATA_HYPERVISOR}."
    fi

    if [ "${SNAPSHOTTER}" != "nydus" ] && [ -z "${EXPERIMENTAL_FORCE_GUEST_PULL}" ]; then
        skip "Either SNAPSHOTTER=nydus or EXPERIMENTAL_FORCE_GUEST_PULL must be set for this test"
    fi

    setup_common || die "setup_common failed"
    test_image_supplemental_groups="10"
    UNSIGNED_UNPROTECTED_REGISTRY_IMAGE="${UNSIGNED_UNPROTECTED_REGISTRY_IMAGE:-quay.io/prometheus/busybox:latest}"
    UNSIGNED_PROTECTED_REGISTRY_IMAGE="${UNSIGNED_PROTECTED_REGISTRY_IMAGE:-ghcr.io/confidential-containers/test-container-image-rs:unsigned}"
    COSIGN_SIGNED_PROTECTED_REGISTRY_IMAGE="${COSIGN_SIGNED_PROTECTED_REGISTRY_IMAGE:-ghcr.io/confidential-containers/test-container-image-rs:cosign-signed}"
    COSIGNED_SIGNED_PROTECTED_REGISTRY_WRONG_KEY_IMAGE="${COSIGNED_SIGNED_PROTECTED_REGISTRY_WRONG_KEY_IMAGE:-ghcr.io/confidential-containers/test-container-image-rs:cosign-signed-key2}"
    COSIGN_SIGNED_REGISTRY_PATH="${COSIGN_SIGNED_REGISTRY_PATH:-ghcr.io/confidential-containers/test-container-image-rs}"
    UNSIGNED_PROTECTED_REGISTRY_PATH="${UNSIGNED_PROTECTED_REGISTRY_PATH:-${COSIGN_SIGNED_REGISTRY_PATH}}"
    UNSIGNED_UNPROTECTED_REGISTRY_PATH="${UNSIGNED_UNPROTECTED_REGISTRY_PATH:-quay.io/prometheus}"
    SECURITY_POLICY_KBS_URI="kbs:///default/security-policy/test"
    policy_settings_dir="$(create_tmp_policy_settings_dir "${pod_config_dir}")"
}

function setup_kbs_image_policy() {
    if [ "${KBS}" = "false" ]; then
        skip "Test skipped as KBS not setup"
    fi

    default_policy="${1:-insecureAcceptAnything}"
    local sigstore_entry='"type": "sigstoreSigned", "keyPath": "kbs:///default/cosign-public-key/test"'
    policy_json='{"default": [{"type": "'"${default_policy}"'"}], "transports": {"docker": {'
    policy_json+='"'"${COSIGN_SIGNED_REGISTRY_PATH}"'": [{'"${sigstore_entry}"'}]'
    if [ "${UNSIGNED_PROTECTED_REGISTRY_PATH}" != "${COSIGN_SIGNED_REGISTRY_PATH}" ]; then
        policy_json+=', "'"${UNSIGNED_PROTECTED_REGISTRY_PATH}"'": [{'"${sigstore_entry}"'}]'
    fi
    policy_json+=', "'"${UNSIGNED_UNPROTECTED_REGISTRY_PATH}"'": [{"type": "insecureAcceptAnything"}]'
    policy_json+='}}}'

    if [ -n "${COSIGN_PUBLIC_KEY_FILE:-}" ] && [ -f "${COSIGN_PUBLIC_KEY_FILE}" ]; then
        public_key=$(cat "${COSIGN_PUBLIC_KEY_FILE}")
    else
        COSIGN_PUBLIC_KEY_URL="${COSIGN_PUBLIC_KEY_URL:-https://raw.githubusercontent.com/confidential-containers/infra/main/container-images/keys/sign/cosign.pub}"
        public_key=$(curl -sSL "${COSIGN_PUBLIC_KEY_URL}")
    fi

    if ! is_confidential_hardware; then
        kbs_set_allow_all_resources
    fi

    kbs_set_resource "default" "security-policy" "test" "${policy_json}"
    kbs_set_resource "default" "cosign-public-key" "test" "${public_key}"
}

function get_initdata_with_security_policy() {

    image_section_with_policy=$(cat << EOF
[image]
image_security_policy_uri = "${SECURITY_POLICY_KBS_URI}"
EOF
    )

    get_initdata_with_cdh_image_section "${image_section_with_policy}"
}

@test "Create a pod from an unsigned image, on an insecureAcceptAnything registry works" {
    # downstream-only: skip kernel-param variant, initdata equivalent exists (test 6)
    skip "Initdata equivalent exists"
    # We want to set the default policy to be reject to rule out false positives
    setup_kbs_image_policy "reject"

    create_coco_pod_yaml "${UNSIGNED_UNPROTECTED_REGISTRY_IMAGE}" "${SECURITY_POLICY_KBS_URI}" "" "" "resource" "$node" \
        "" "" "${test_image_supplemental_groups}"
    auto_generate_policy "${policy_settings_dir}" "${kata_pod}"

    # For debug sake
    echo "Pod ${kata_pod}: $(cat ${kata_pod})"

    k8s_create_pod "${kata_pod}"
    echo "Kata pod test-e2e from image security policy is running"
}

@test "Create a pod from an unsigned image, on a 'restricted registry' is rejected" {
    # downstream-only: skip kernel-param variant, initdata equivalent exists (test 7)
    skip "Initdata equivalent exists"
    # We want to leave the default policy to be insecureAcceptAnything to rule out false negatives
    setup_kbs_image_policy

    create_coco_pod_yaml "${UNSIGNED_PROTECTED_REGISTRY_IMAGE}" "${SECURITY_POLICY_KBS_URI}" "" "" "resource" "$node" \
        "" "" "${test_image_supplemental_groups}"
    auto_generate_policy "${policy_settings_dir}" "${kata_pod}"

    # For debug sake
    echo "Pod ${kata_pod}: $(cat ${kata_pod})"

    assert_pod_fail "${kata_pod}"
    assert_logs_contain "${node}" kata "${node_start_time}" "Image policy rejected: Denied by policy"
}

@test "Create a pod from a signed image, on a 'restricted registry' is successful" {
    # downstream-only: skip kernel-param variant, initdata equivalent exists (test 8)
    skip "Initdata equivalent exists"
    # We want to set the default policy to be reject to rule out false positives
    setup_kbs_image_policy "reject"

    create_coco_pod_yaml "${COSIGN_SIGNED_PROTECTED_REGISTRY_IMAGE}" "${SECURITY_POLICY_KBS_URI}" "" "" "resource" "$node" \
        "" "" "${test_image_supplemental_groups}"
    auto_generate_policy "${policy_settings_dir}" "${kata_pod}"

    # For debug sake
    echo "Pod ${kata_pod}: $(cat ${kata_pod})"

    k8s_create_pod "${kata_pod}"
    echo "Kata pod test-e2e from image security policy is running"
}

@test "Create a pod from a signed image, on a 'restricted registry', but with the wrong key is rejected" {
    # downstream-only: skip kernel-param variant, initdata equivalent exists (test 9)
    skip "Initdata equivalent exists"
    # We want to leave the default policy to be insecureAcceptAnything to rule out false negatives
    setup_kbs_image_policy

    create_coco_pod_yaml "${COSIGNED_SIGNED_PROTECTED_REGISTRY_WRONG_KEY_IMAGE}" "${SECURITY_POLICY_KBS_URI}" "" "" "resource" "$node" \
        "" "" "${test_image_supplemental_groups}"
    auto_generate_policy "${policy_settings_dir}" "${kata_pod}"

    # For debug sake
    echo "Pod ${kata_pod}: $(cat ${kata_pod})"

    assert_pod_fail "${kata_pod}"
    assert_logs_contain "${node}" kata "${node_start_time}" "Image policy rejected: Denied by policy"
}

@test "Create a pod from an unsigned image, on a 'restricted registry' works if policy files isn't set" {
    # downstream-only: skip kernel-param variant, initdata equivalent exists (test 10)
    skip "Initdata equivalent exists"
    # We want to set the default policy to be reject to rule out false positives
    setup_kbs_image_policy "reject"

    create_coco_pod_yaml "${UNSIGNED_PROTECTED_REGISTRY_IMAGE}" "" "" "" "resource" "$node" \
        "" "" "${test_image_supplemental_groups}"
    auto_generate_policy "${policy_settings_dir}" "${kata_pod}"

    # For debug sake
    echo "Pod ${kata_pod}: $(cat ${kata_pod})"

    k8s_create_pod "${kata_pod}"
    echo "Kata pod test-e2e from image security policy is running"
}

@test "Create a pod from an unsigned image, on an insecureAcceptAnything registry works (with initdata)" {


    # We want to set the default policy to be reject to rule out false positives
    setup_kbs_image_policy "reject"

    initdata=$(get_initdata_with_security_policy)
    create_coco_pod_yaml_with_annotations "${UNSIGNED_UNPROTECTED_REGISTRY_IMAGE}" "" "${initdata}" "${node}" \
        "" "" "${test_image_supplemental_groups}"
    auto_generate_policy "${policy_settings_dir}" "${kata_pod}"

    # For debug sake
    echo "Pod ${kata_pod}: $(cat ${kata_pod})"

    k8s_create_pod "${kata_pod}"
    echo "Kata pod test-e2e from image security policy is running"
}

@test "Create a pod from an unsigned image, on a 'restricted registry' is rejected (with initdata)" {


    # We want to leave the default policy to be insecureAcceptAnything to rule out false negatives
    setup_kbs_image_policy

    initdata=$(get_initdata_with_security_policy)
    create_coco_pod_yaml_with_annotations "${UNSIGNED_PROTECTED_REGISTRY_IMAGE}" "" "${initdata}" "${node}" \
        "" "" "${test_image_supplemental_groups}"
    auto_generate_policy "${policy_settings_dir}" "${kata_pod}"

    # For debug sake
    echo "Pod ${kata_pod}: $(cat ${kata_pod})"

    assert_pod_fail "${kata_pod}"
    assert_logs_contain "${node}" kata "${node_start_time}" "Image policy rejected: Denied by policy"
}

@test "Create a pod from a signed image, on a 'restricted registry' is successful (with initdata)" {


    # We want to set the default policy to be reject to rule out false positives
    setup_kbs_image_policy "reject"

    initdata=$(get_initdata_with_security_policy)
    create_coco_pod_yaml_with_annotations "${COSIGN_SIGNED_PROTECTED_REGISTRY_IMAGE}" "" "${initdata}" "${node}" \
        "" "" "${test_image_supplemental_groups}"
    auto_generate_policy "${policy_settings_dir}" "${kata_pod}"

    # For debug sake
    echo "Pod ${kata_pod}: $(cat ${kata_pod})"

    k8s_create_pod "${kata_pod}"
    echo "Kata pod test-e2e from image security policy is running"
}

@test "Create a pod from a signed image, on a 'restricted registry', but with the wrong key is rejected (with initdata)" {


    # We want to leave the default policy to be insecureAcceptAnything to rule out false negatives
    setup_kbs_image_policy

    initdata=$(get_initdata_with_security_policy)
    create_coco_pod_yaml_with_annotations "${COSIGNED_SIGNED_PROTECTED_REGISTRY_WRONG_KEY_IMAGE}" "" "${initdata}" "${node}" \
        "" "" "${test_image_supplemental_groups}"
    auto_generate_policy "${policy_settings_dir}" "${kata_pod}"

    # For debug sake
    echo "Pod ${kata_pod}: $(cat ${kata_pod})"

    assert_pod_fail "${kata_pod}"
    assert_logs_contain "${node}" kata "${node_start_time}" "Image policy rejected: Denied by policy"
}

@test "Create a pod from an unsigned image, on a 'restricted registry' works if policy files isn't set (with initdata)" {


    # We want to set the default policy to be reject to rule out false positives
    setup_kbs_image_policy "reject"

    create_coco_pod_yaml_with_annotations "${UNSIGNED_PROTECTED_REGISTRY_IMAGE}" "" "" "${node}" \
        "" "" "${test_image_supplemental_groups}"
    auto_generate_policy "${policy_settings_dir}" "${kata_pod}"

    # For debug sake
    echo "Pod ${kata_pod}: $(cat ${kata_pod})"

    k8s_create_pod "${kata_pod}"
    echo "Kata pod test-e2e from image security policy is running"
}

teardown() {
    if ! is_confidential_runtime_class; then
        skip "Test not supported for ${KATA_HYPERVISOR}."
    fi

    if [ "${SNAPSHOTTER}" != "nydus" ] && [ -z "${EXPERIMENTAL_FORCE_GUEST_PULL}" ]; then
        skip "Either SNAPSHOTTER=nydus or EXPERIMENTAL_FORCE_GUEST_PULL must be set for this test"
    fi

    delete_tmp_policy_settings_dir "${policy_settings_dir:-}"
    teardown_common "${node}" "${node_start_time:-}"
}
