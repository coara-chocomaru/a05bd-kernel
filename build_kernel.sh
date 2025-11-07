#!/bin/bash
set -e
set -o pipefail

if [ "$#" -eq 1 ]; then
    TARGET_DIR="$1"
elif [ "$#" -eq 2 ]; then
    PLATFORM_TARBALL="$1"
    TARGET_DIR="$2"
else
    echo "Usage: ${BASH_SOURCE[0]} [path_to_platform_tar] output_folder" 1>&2
    exit 1
fi

SCRIPT_BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_BASE_DIR}/build_kernel_config.sh"
PATCH_FILE="${SCRIPT_BASE_DIR}/platform_patch.txt"

WORKSPACE_DIR="$(pwd)/build"
TOOLCHAIN_DIR="${WORKSPACE_DIR}/toolchain"
PLATFORM_EXTRACT_DIR="${WORKSPACE_DIR}/src"
WORKSPACE_OUT_DIR="${WORKSPACE_DIR}/out"
OUTPUT_CFG="${WORKSPACE_OUT_DIR}/.config"

for d in "${TOOLCHAIN_DIR}" "${PLATFORM_EXTRACT_DIR}" "${WORKSPACE_OUT_DIR}"
do
    mkdir -p "${d}"
done

PARALLEL_EXECUTION="-j5"

usage() {
    echo "Usage: ${BASH_SOURCE[0]} [path_to_platform_tar] output_folder" 1>&2
    exit 1
}

validate_input_params() {
    if [[ ! -f "${CONFIG_FILE}" ]]; then
        echo "ERROR: Could not find config file ${CONFIG_FILE}."
        usage
    fi
}

display_config() {
    echo "-------------------------------------------------------------------------"
    echo "SOURCE TARBALL: ${PLATFORM_TARBALL:-}"
    echo "TARGET DIRECTORY: ${TARGET_DIR}"
    echo "KERNEL SUBPATH: ${KERNEL_SUBPATH:-}"
    echo "DEFINITION CONFIG: ${DEFCONFIG_NAME:-}"
    echo "TARGET ARCHITECTURE: ${TARGET_ARCH:-}"
    echo "TOOLCHAIN REPO: ${TOOLCHAIN_REPO:-}"
    echo "TOOLCHAIN PREFIX: ${TOOLCHAIN_PREFIX:-}"
    echo "-------------------------------------------------------------------------"
    echo "Sleeping 3 seconds before continuing."
    sleep 3
}

setup_output_dir() {
    if [[ -d "${TARGET_DIR}" ]]; then
        FILECOUNT=$(find "${TARGET_DIR}" -type f | wc -l)
        if [[ ${FILECOUNT} -gt 0 ]]; then
            echo "ERROR: Destination folder is not empty. Refusing to build to a non-clean target"
            exit 3
        fi
    else
        echo "Making target directory ${TARGET_DIR}"
        mkdir -p "${TARGET_DIR}"
        if [[ $? -ne 0 ]]; then
            echo "ERROR: Could not make target directory ${TARGET_DIR}"
            exit 1
        fi
    fi
}

download_toolchain() {
    if [[ -z "${TOOLCHAIN_REPO:-}" || -z "${TOOLCHAIN_BRANCH:-}" ]]; then
        echo "TOOLCHAIN_REPO or TOOLCHAIN_BRANCH not set in config; skipping clone."
        return 0
    fi
    echo "Cloning toolchain ${TOOLCHAIN_REPO} to ${TOOLCHAIN_DIR}"
    git clone --single-branch -b "${TOOLCHAIN_BRANCH}" "${TOOLCHAIN_REPO}" "${TOOLCHAIN_DIR}" --depth=1 || {
        echo "ERROR: Could not clone toolchain from ${TOOLCHAIN_REPO}."
        exit 2
    }
}

download_toolchain2() {
    echo "Cloning toolchain https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86 to toolchain/clang"
    git clone --single-branch -b android-9.0.0_r6 https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86 "$(pwd)/toolchain/clang" --depth=1 || {
        echo "ERROR: Could not clone toolchain from https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86."
        exit 2
    }
}

extract_tarball() {
    if [[ -n "${PLATFORM_TARBALL:-}" && -f "${PLATFORM_TARBALL}" ]]; then
        echo "Extracting tarball to ${PLATFORM_EXTRACT_DIR}"
        mkdir -p "${PLATFORM_EXTRACT_DIR}"
        tar xf "${PLATFORM_TARBALL}" -C "${PLATFORM_EXTRACT_DIR}"
    else
        echo "No platform tarball provided; using repository working tree at ${SCRIPT_BASE_DIR}"
        PLATFORM_EXTRACT_DIR="${SCRIPT_BASE_DIR}"
    fi
}

apply_patch() {
    if [[ -f "${PATCH_FILE}" ]]; then
        echo "Applying patch to ${PLATFORM_EXTRACT_DIR}"
        pushd "${PLATFORM_EXTRACT_DIR}" > /dev/null
        set +e
        patch -p1 < "${PATCH_FILE}" 2>/dev/null
        RET=$?
        if [[ ${RET} -ne 0 ]]; then
            patch -p0 < "${PATCH_FILE}" 2>/dev/null || echo "Patch apply failed or skipped"
        fi
        set -e
        popd > /dev/null
    fi
}

exec_build_kernel() {
    CCOMPILE=""
    if [[ -n "${TOOLCHAIN_PREFIX:-}" && -d "${TOOLCHAIN_DIR}/bin" && -x "${TOOLCHAIN_DIR}/bin/${TOOLCHAIN_PREFIX}gcc" ]]; then
        CCOMPILE="${TOOLCHAIN_DIR}/bin/${TOOLCHAIN_PREFIX}"
    elif [[ -d "${TOOLCHAIN_DIR}/bin" ]]; then
        CCOMPILE="$(ls "${TOOLCHAIN_DIR}/bin" | head -n1 2>/dev/null || true)"
        CCOMPILE="${TOOLCHAIN_DIR}/bin/${CCOMPILE}"
    fi

    if [[ -n "${CLANG_COMPILER_PATH:-}" && -x "${CLANG_COMPILER_PATH}/bin/clang" ]]; then
        CC="${CLANG_COMPILER_PATH}/bin/clang"
    elif [[ -x "$(command -v clang 2>/dev/null)" ]]; then
        CC="clang"
    else
        CC="${TOOLCHAIN_DIR}/bin/${TOOLCHAIN_PREFIX}gcc"
    fi

    MAKE_ARGS="-C ${KERNEL_SUBPATH} O=${WORKSPACE_OUT_DIR} ARCH=${TARGET_ARCH}"
    MAKE_ARGS1="-C ${KERNEL_SUBPATH} O=${WORKSPACE_OUT_DIR} ARCH=${TARGET_ARCH} CROSS_COMPILE=${CCOMPILE} CLANG_TRIPLE=aarch64-linux-gnu- CC=${CC}"
    echo "MAKE_ARGS: ${MAKE_ARGS}"
    echo "MAKE_ARGS1: ${MAKE_ARGS1}"

    pushd "${PLATFORM_EXTRACT_DIR}" > /dev/null

    echo "Make defconfig: make ${MAKE_ARGS} ${DEFCONFIG_NAME}"
    make ${MAKE_ARGS} ${DEFCONFIG_NAME} || true

    echo ".config contents"
    echo "---------------------------------------------------------------------"
    if [[ -f "${OUTPUT_CFG}" ]]; then
        cat "${OUTPUT_CFG}"
    else
        echo "No output .config found at ${OUTPUT_CFG}"
    fi
    echo "---------------------------------------------------------------------"

    echo "Running full make"
    make ${PARALLEL_EXECUTION} ${MAKE_ARGS1}

    popd > /dev/null
}

copy_to_output() {
    echo "Copying files to output"
    pushd "${WORKSPACE_OUT_DIR}" > /dev/null
    find "./arch/${TARGET_ARCH}/boot" -type f -print0 2>/dev/null | while IFS= read -r -d '' CPFILE; do
        REL="${CPFILE#./}"
        BASEDIR="$(dirname "${REL}")"
        if [[ ! -d "${TARGET_DIR}/${BASEDIR}" ]]; then
            mkdir -p "${TARGET_DIR}/${BASEDIR}"
        fi
        cp -v "${REL}" "${TARGET_DIR}/${REL}"
    done
    popd > /dev/null
}

validate_output() {
    echo "Listing output files"
    IFS=":"
    for IMAGE in ${KERNEL_IMAGES:-}; do
        if [ -z "${IMAGE}" ]; then
            continue
        fi
        if [ ! -f "${TARGET_DIR}/${IMAGE}" ]; then
            echo "ERROR: Missing kernel output image ${IMAGE}" >&2
            exit 1
        fi
        ls -l "${TARGET_DIR}/${IMAGE}"
    done
}

validate_input_params
source "${CONFIG_FILE}"
setup_output_dir
TARGET_DIR="$(cd "${TARGET_DIR}" && pwd)"
display_config

if [ -n "${TOOLCHAIN_NAME:-}" ]; then
    TOOLCHAIN_DIR="$(pwd)/toolchain/${TOOLCHAIN_NAME}"
fi
if [ -z "$(ls -A "${TOOLCHAIN_DIR}" 2>/dev/null || true)" ]; then
    download_toolchain
fi
if [ -z "$(ls -A "$(pwd)/toolchain/clang" 2>/dev/null || true)" ]; then
    download_toolchain2
fi

extract_tarball
apply_patch
exec_build_kernel
copy_to_output
validate_output
