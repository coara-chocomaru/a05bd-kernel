#!/bin/bash

TARGET_DIR="${1}"

SCRIPT_BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CONFIG_FILE="${SCRIPT_BASE_DIR}/build_kernel_config.sh"
PATCH_FILE="${SCRIPT_BASE_DIR}/platform_patch.txt"

WORKSPACE_DIR="$(pwd)/build"
TOOLCHAIN_DIR="${WORKSPACE_DIR}/toolchain"
PLATFORM_EXTRACT_DIR="${WORKSPACE_DIR}/src"
WORKSPACE_OUT_DIR="${WORKSPACE_DIR}/out"
OUTPUT_CFG="${WORKSPACE_OUT_DIR}/.config"

PARALLEL_EXECUTION="-j5"

function usage {
    echo "Usage: ${BASH_SOURCE[0]} output_folder" 1>&2
    exit 1
}

function validate_input_params {
    if [[ ! -f "${CONFIG_FILE}" ]]
    then
        echo "ERROR: Could not find config file ${CONFIG_FILE}. Please check that you have extracted the build script properly and try again."
        usage
    fi
}

function display_config {
    echo "-------------------------------------------------------------------------"
    echo "TARGET DIRECTORY: ${TARGET_DIR}"
    echo "KERNEL SUBPATH: ${KERNEL_SUBPATH}"
    echo "DEFINITION CONFIG: ${DEFCONFIG_NAME}"
    echo "TARGET ARCHITECTURE: ${TARGET_ARCH}"
    echo "TOOLCHAIN REPO: ${TOOLCHAIN_REPO}"
    echo "TOOLCHAIN PREFIX: ${TOOLCHAIN_PREFIX}"
    echo "-------------------------------------------------------------------------"
    echo "Sleeping 3 seconds before continuing."
    sleep 3
}

function setup_output_dir {
    if [[ -d "${TARGET_DIR}" ]]
    then
        FILECOUNT=$(find "${TARGET_DIR}" -type f | wc -l)
        if [[ ${FILECOUNT} -gt 0 ]]
        then
            echo "ERROR: Destination folder is not empty. Refusing to build to a non-clean target"
            exit 3
        fi
    else
        echo "Making target directory ${TARGET_DIR}"
        mkdir -p "${TARGET_DIR}"
        if [[ $? -ne 0 ]]
        then
            echo "ERROR: Could not make target directory ${TARGET_DIR}"
            exit 1
        fi
    fi
}

function download_toolchain {
    echo "Cloning toolchain ${TOOLCHAIN_REPO} to ${TOOLCHAIN_DIR}"
    git clone --single-branch -b "${TOOLCHAIN_BRANCH}" "${TOOLCHAIN_REPO}" "${TOOLCHAIN_DIR}" --depth=1
    if [[ $? -ne 0 ]]
    then
        echo "ERROR: Could not clone toolchain from ${TOOLCHAIN_REPO}."
        exit 2
    fi
}

function download_toolchain2 {
    echo "Cloning clang toolchain to $(pwd)/toolchain/clang"
    git -c advice.detachedHead=false clone --single-branch -b android-9.0.0_r6 \
        https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86 \
        "$(pwd)/toolchain/clang" --depth=1
    if [[ $? -ne 0 ]]; then
        echo "ERROR: Could not clone clang toolchain."
        exit 2
    fi
}

function apply_patch {
    if [[ -f "${PATCH_FILE}" ]]
    then
        echo "Applying patch to ${PLATFORM_EXTRACT_DIR}"
        pushd "${PLATFORM_EXTRACT_DIR}" > /dev/null
        patch -p1 < "${PATCH_FILE}"
        popd > /dev/null
    fi
}

function exec_build_kernel {
    CCOMPILE="${TOOLCHAIN_DIR}/bin/${TOOLCHAIN_PREFIX}"
    CLANG_DIR="$(pwd)/toolchain/clang"
    if [[ ! -d "${CLANG_DIR}" ]]; then
        echo "ERROR: Clang directory not found at ${CLANG_DIR}"
        exit 1
    fi
    CC="${CLANG_DIR}/bin/clang"

    MAKE_ARGS=""
    [[ -n "${KERNEL_SUBPATH}" ]] && MAKE_ARGS="-C ${KERNEL_SUBPATH}"
    MAKE_ARGS="${MAKE_ARGS} O=${WORKSPACE_OUT_DIR} ARCH=${TARGET_ARCH}"
    MAKE_ARGS1="${MAKE_ARGS} CROSS_COMPILE=${CCOMPILE} CLANG_TRIPLE=aarch64-linux-gnu- CC=${CC}"

    echo "MAKE_ARGS: ${MAKE_ARGS}"
    echo "MAKE_ARGS1: ${MAKE_ARGS1}"

    pushd "${PLATFORM_EXTRACT_DIR}" > /dev/null

    echo "Make defconfig: make ${MAKE_ARGS} ${DEFCONFIG_NAME}"
    make ${MAKE_ARGS} ${DEFCONFIG_NAME}

    echo ".config contents"
    echo "---------------------------------------------------------------------"
    cat "${OUTPUT_CFG}"
    echo "---------------------------------------------------------------------"

    echo "Running full make"
    make ${PARALLEL_EXECUTION} ${MAKE_ARGS1}

    if [[ $? -ne 0 ]]; then
        echo "ERROR: Failed to build kernel" >&2
        exit 1
    fi

    popd > /dev/null
}

function copy_to_output {
    echo "Copying files to output"

    pushd "${WORKSPACE_OUT_DIR}" > /dev/null
    find "arch/${TARGET_ARCH}/boot" -type f | sed 's|^\./||' | while read -r CPFILE
    do
        BASEDIR="$(dirname "${CPFILE}")"
        mkdir -p "${TARGET_DIR}/${BASEDIR}"
        cp -v "${CPFILE}" "${TARGET_DIR}/${CPFILE}"
    done
    popd > /dev/null
}

function validate_output {
    echo "Listing output files"
    IFS=":"
    for IMAGE in ${KERNEL_IMAGES}; do
        if [[ ! -f "${TARGET_DIR}/${IMAGE}" ]]; then
            echo "ERROR: Missing kernel output image ${IMAGE}" >&2
            exit 1
        fi
        ls -l "${TARGET_DIR}/${IMAGE}"
    done
}

mkdir -p "${WORKSPACE_DIR}"
for d in "${TOOLCHAIN_DIR}" "${PLATFORM_EXTRACT_DIR}" "${WORKSPACE_OUT_DIR}"; do
    mkdir -p "${d}"
done

validate_input_params
source "${CONFIG_FILE}"
setup_output_dir
TARGET_DIR="$(cd "${TARGET_DIR}" && pwd)"
display_config

if [[ -n "${TOOLCHAIN_NAME}" ]]; then
    TOOLCHAIN_DIR="$(pwd)/toolchain/${TOOLCHAIN_NAME}"
fi

if [[ -z "$(ls -A "${TOOLCHAIN_DIR}")" ]]; then
    download_toolchain
fi

if [[ -z "$(ls -A "$(pwd)/toolchain/clang")" ]]; then
    download_toolchain2
fi

apply_patch
exec_build_kernel
copy_to_output
validate_output
