#!/usr/bin/env bash
################################################################################
#
#  build_kernel.sh  (fixed)
#
################################################################################
set -euo pipefail

################################################################################
# I N P U T
################################################################################
TARGET_DIR="${1:-}"

################################################################################
# V A R I A B L E S
################################################################################

# Retrieve the directory where the script is currently held (robust)
if [ -n "${BASH_SOURCE-}" ]; then
    SCRIPT_BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
    # fallback if executed by /bin/sh or other
    SCRIPT_BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
fi

# Configuration file for the build.
CONFIG_FILE="${SCRIPT_BASE_DIR}/build_kernel_config.sh"
PATCH_FILE="${SCRIPT_BASE_DIR}/platform_patch.txt"

# Workspace directory & relevant temp folders.
mkdir -p build
WORKSPACE_DIR="$(pwd)/build"
OUTPUT_CFG="${WORKSPACE_DIR}/.config"
TOOLCHAIN_DIR="${WORKSPACE_DIR}/toolchain"
PLATFORM_EXTRACT_DIR="${WORKSPACE_DIR}/src"
WORKSPACE_OUT_DIR="${WORKSPACE_DIR}/out"

for d in "${TOOLCHAIN_DIR}" "${PLATFORM_EXTRACT_DIR}" "$WORKSPACE_OUT_DIR"
do
    mkdir -p "${d}"
done

PARALLEL_EXECUTION="-j5"

usage() {
    echo "Usage: ${0} path_to_platform_tar output_folder" 1>&2
    exit 1
}

validate_input_params() {
    if [[ ! -f "${CONFIG_FILE}" ]]; then
        echo "ERROR: Could not find config file ${CONFIG_FILE}. Please check" \
             "that you have extracted the build script properly and try again."
        usage
    fi
}

display_config() {
    echo "-------------------------------------------------------------------------"
    echo "SOURCE TARBALL: ${PLATFORM_TARBALL-}"
    echo "TARGET DIRECTORY: ${TARGET_DIR}"
    echo "KERNEL SUBPATH: ${KERNEL_SUBPATH-}"
    echo "DEFINITION CONFIG: ${DEFCONFIG_NAME-}"
    echo "TARGET ARCHITECTURE: ${TARGET_ARCH-}"
    echo "TOOLCHAIN REPO: ${TOOLCHAIN_REPO-}"
    echo "TOOLCHAIN PREFIX: ${TOOLCHAIN_PREFIX-}"
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
    fi
}

download_toolchain() {
    echo "Cloning toolchain ${TOOLCHAIN_REPO} to ${TOOLCHAIN_DIR}"
    git clone --single-branch -b "${TOOLCHAIN_BRANCH}" "${TOOLCHAIN_REPO}" "${TOOLCHAIN_DIR}" --depth=1
    if [[ $? -ne 0 ]]; then
        echo "ERROR: Could not clone toolchain from ${TOOLCHAIN_REPO}."
        exit 2
    fi
}

download_toolchain2() {
    echo "Cloning toolchain https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86 to toolchain/clang"
    git clone --single-branch -b android-9.0.0_r6 https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86 "$(pwd)/toolchain/clang" --depth=1
    if [[ $? -ne 0 ]]; then
        echo "ERROR: Could not clone toolchain from https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86."
        exit 2
    fi
}

extract_tarball() {
    echo "Extracting tarball to ${PLATFORM_EXTRACT_DIR}"
    tar xf "${PLATFORM_TARBALL}" -C "${PLATFORM_EXTRACT_DIR}"
}

apply_patch() {
    if [[ -f "${PATCH_FILE}" ]]; then
        echo "Applying patch to ${PLATFORM_EXTRACT_DIR}"
        pushd "${PLATFORM_EXTRACT_DIR}" >/dev/null
        patch -p1 < "${PATCH_FILE}"
        popd >/dev/null
    fi
}

# ---------------------------
# destructive sanitize: remove MODVERSIONS lines and Module.symvers
# ---------------------------
sanitize_sources() {
    echo "Sanitizing extracted sources: removing MODVERSIONS references and Module.symvers..."

    if [[ ! -d "${PLATFORM_EXTRACT_DIR}" ]]; then
        echo "No extracted platform source directory (${PLATFORM_EXTRACT_DIR}) found; skipping sanitize."
        return 0
    fi

    pushd "${PLATFORM_EXTRACT_DIR}" >/dev/null

    # Remove any line containing MODVERSIONS (case-insensitive) from text files
    while IFS= read -r -d $'\0' f; do
        # only operate on regular files
        if [[ -f "$f" ]]; then
            # remove lines containing MODVERSIONS (case-insensitive)
            sed -i -E '/[Mm][Oo][Dd][Vv][Ee][Rr][Ss][Ii][Oo][Nn][Ss]/d' "$f" || true
            # remove explicit CONFIG_MODVERSIONS assignments
            sed -i -E '/^CONFIG_MODVERSIONS[[:space:]]*=/Id' "$f" || true
        fi
    done < <(find . -type f -print0)

    # Delete any Module.symvers files anywhere under source tree
    find . -type f -name "Module.symvers" -exec rm -f {} +

    popd >/dev/null

    echo "Sanitization complete."
}

exec_build_kernel() {
    CCOMPILE="${TOOLCHAIN_DIR}/bin/${TOOLCHAIN_PREFIX}"
    CC="${CLANG_COMPILER_PATH}/bin/clang"

    if [[ -n "${KERNEL_SUBPATH-}" ]]; then
        MAKE_ARGS="-C ${KERNEL_SUBPATH}"
    fi

    MAKE_ARGS="-C ${KERNEL_SUBPATH} O=${WORKSPACE_OUT_DIR} ARCH=${TARGET_ARCH}"
    MAKE_ARGS1="-C ${KERNEL_SUBPATH} O=${WORKSPACE_OUT_DIR} ARCH=${TARGET_ARCH} CROSS_COMPILE=${CCOMPILE} CLANG_TRIPLE=aarch64-linux-gnu- CC=${CC}"
    echo "MAKE_ARGS: ${MAKE_ARGS}"
    echo "MAKE_ARGS1: ${MAKE_ARGS1}"

    pushd "${PLATFORM_EXTRACT_DIR}" >/dev/null

    echo "Make defconfig: make ${MAKE_ARGS} ${DEFCONFIG_NAME}"
    make ${MAKE_ARGS} ${DEFCONFIG_NAME}

    echo ".config contents"
    echo "---------------------------------------------------------------------"
    if [[ -f "${OUTPUT_CFG}" ]]; then
        cat "${OUTPUT_CFG}"
    else
        echo ".config not found at ${OUTPUT_CFG}"
    fi
    echo "---------------------------------------------------------------------"

    echo "Running full make"
    make ${PARALLEL_EXECUTION} ${MAKE_ARGS1}

    popd >/dev/null
}

copy_to_output() {
    echo "Copying files to output"
    pushd "${WORKSPACE_OUT_DIR}" >/dev/null
    find "./arch/${TARGET_ARCH}/boot" -type f | sed 's|^\./||' | while read -r CPFILE; do
        BASEDIR="$(dirname "${CPFILE}")"
        if [[ ! -d "${TARGET_DIR}/${BASEDIR}" ]]; then
            mkdir -p "${TARGET_DIR}/${BASEDIR}"
        fi
        cp -v "${CPFILE}" "${TARGET_DIR}/${CPFILE}"
    done
    popd >/dev/null
}

validate_output() {
    echo "Listing output files"
    local IFS=":"
    for IMAGE in ${KERNEL_IMAGES}; do
        if [ ! -f "${TARGET_DIR}/${IMAGE}" ]; then
            echo "ERROR: Missing kernel output image ${IMAGE}" >&2
            exit 1
        fi
        ls -l "${TARGET_DIR}/${IMAGE}"
    done
}

################################################################################
# M A I N
################################################################################

validate_input_params
source "${CONFIG_FILE}"
setup_output_dir
TARGET_DIR="$(cd "${TARGET_DIR}" && pwd)"
display_config

if [ -n "${TOOLCHAIN_NAME-}" ]; then
    TOOLCHAIN_DIR="$(pwd)/toolchain/${TOOLCHAIN_NAME}"
fi
if [ -z "$(ls -A "${TOOLCHAIN_DIR}")" ]; then
    download_toolchain
fi
if [ -z "$(ls -A "$(pwd)/toolchain/clang")" ]; then
    download_toolchain2
fi

apply_patch

# <<< sanitize extracted source tree BEFORE building (destructive) >>>
sanitize_sources

# build
exec_build_kernel

# move to output
copy_to_output

# verify
validate_output
