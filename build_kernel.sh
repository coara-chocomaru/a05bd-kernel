#!/bin/bash

################################################################################
#
#  build_kernel_config.sh
#
#  Copyright (c) 2019 Amazon.com, Inc. or its affiliates. All Rights Reserved.
#
#  Modified for building with a05bd_defconfig on Ubuntu 20.04 container.
#  This script sets up the environment, downloads necessary toolchains,
#  configures the kernel with the specified defconfig, and builds it.
#
################################################################################

# Kernel source subpath (adjust if your kernel source is located differently)
KERNEL_SUBPATH="kernel/mediatek/mt8168/4.14"

# Defconfig name
DEFCONFIG_NAME="a05bd_defconfig"

# Target architecture
TARGET_ARCH="arm64"

# Toolchain repository for GCC (AOSP prebuilts)
TOOLCHAIN_REPO="https://android.googlesource.com/platform/prebuilts/gcc/linux-x86/aarch64/aarch64-linux-android-4.9"

# Toolchain branch
TOOLCHAIN_BRANCH="llvm-r383902b"

# Toolchain name
TOOLCHAIN_NAME="aarch64-linux-android-4.9"

# Toolchain prefix
TOOLCHAIN_PREFIX="aarch64-linux-android-"

# Expected image files are separated with ":"
KERNEL_IMAGES="arch/arm64/boot/Image:arch/arm64/boot/Image.gz:arch/arm64/boot/Image.gz-dtb"

################################################################################
# NOTE: You must fill in the following with the path to a copy of Clang compiler
# Recommended version 6.0.2 (or 4691093).
# Adjust this path if Clang is installed elsewhere in your container.
################################################################################
CLANG_COMPILER_PATH="$(pwd)/toolchain/clang/clang-4691093"

# Additional variables
KERNEL_SRC_DIR="$(pwd)/${KERNEL_SUBPATH}"
TOOLCHAIN_DIR="$(pwd)/toolchain/${TOOLCHAIN_NAME}"
BUILD_DIR="$(pwd)/build"
JOBS="$(nproc)"  # Number of parallel jobs (use all available cores)

# Function to download and set up toolchain if not present
setup_toolchain() {
    if [ ! -d "${TOOLCHAIN_DIR}" ]; then
        echo "Downloading toolchain from ${TOOLCHAIN_REPO} branch ${TOOLCHAIN_BRANCH}..."
        mkdir -p "$(dirname ${TOOLCHAIN_DIR})"
        git clone --branch "${TOOLCHAIN_BRANCH}" "${TOOLCHAIN_REPO}" "${TOOLCHAIN_DIR}"
        if [ $? -ne 0 ]; then
            echo "Failed to download toolchain. Exiting."
            exit 1
        fi
    else
        echo "Toolchain already exists at ${TOOLCHAIN_DIR}."
    fi
}

# Function to check if Clang is available
check_clang() {
    if [ ! -d "${CLANG_COMPILER_PATH}" ]; then
        echo "Clang compiler not found at ${CLANG_COMPILER_PATH}."
        echo "Please download and extract Clang (recommended version 4691093) to this path."
        echo "You can obtain it from AOSP or other sources."
        exit 1
    fi
    echo "Clang found at ${CLANG_COMPILER_PATH}."
}

# Main build function
build_kernel() {
    # Change to kernel source directory
    cd "${KERNEL_SRC_DIR}" || { echo "Kernel source directory not found: ${KERNEL_SRC_DIR}"; exit 1; }

    # Create build directory if not exists
    mkdir -p "${BUILD_DIR}"

    # Set environment variables
    export ARCH="${TARGET_ARCH}"
    export CROSS_COMPILE="${TOOLCHAIN_DIR}/bin/${TOOLCHAIN_PREFIX}"
    export PATH="${CLANG_COMPILER_PATH}/bin:${TOOLCHAIN_DIR}/bin:${PATH}"
    export CLANG_TRIPLE=aarch64-linux-gnu-
    export CC="${CLANG_COMPILER_PATH}/bin/clang"
    export LD="${CLANG_COMPILER_PATH}/bin/ld.lld"  # Use LLD if available for linking

    # Clean previous build (optional, comment out if not needed)
    make O="${BUILD_DIR}" clean

    # Configure with defconfig
    echo "Configuring kernel with ${DEFCONFIG_NAME}..."
    make O="${BUILD_DIR}" "${DEFCONFIG_NAME}"
    if [ $? -ne 0 ]; then
        echo "Failed to configure kernel. Exiting."
        exit 1
    fi

    # Build the kernel
    echo "Building kernel with ${JOBS} jobs..."
    make O="${BUILD_DIR}" -j"${JOBS}"
    if [ $? -ne 0 ]; then
        echo "Kernel build failed. Exiting."
        exit 1
    fi

    # Check for expected images
    for image in $(echo "${KERNEL_IMAGES}" | tr ':' ' '); do
        if [ -f "${BUILD_DIR}/${image}" ]; then
            echo "Kernel image built: ${BUILD_DIR}/${image}"
        else
            echo "Warning: Expected image not found: ${image}"
        fi
    done
}

# Main execution
echo "Starting kernel build script..."

# Setup dependencies (assuming running in Ubuntu 20.04 container)
# Install required packages if not already installed
apt-get update && apt-get install -y git build-essential bc bison flex libssl-dev python3

setup_toolchain
check_clang
build_kernel

echo "Kernel build completed."
