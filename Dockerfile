FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# Install build dependencies
RUN apt-get update && apt-get install -y \
    build-essential \
    cmake \
    pkg-config \
    git \
    python3 \
    python3-dev \
    libreadline-dev \
    libffi-dev \
    bison \
    flex \
    libboost-all-dev \
    libeigen3-dev \
    clang \
    iverilog \
    tcl-dev \
    libftdi-dev \
    && rm -rf /var/lib/apt/lists/*

# Build IceStorm (pinned release)
RUN git clone --depth 1 --branch v1.1 https://github.com/YosysHQ/icestorm.git /tmp/icestorm && \
    cd /tmp/icestorm && \
    make -j$(nproc) && \
    make install && \
    rm -rf /tmp/icestorm

# Build Yosys (pinned release)
RUN git clone --depth 1 --branch yosys-0.44 --recursive https://github.com/YosysHQ/yosys.git /tmp/yosys && \
    cd /tmp/yosys && \
    make -j$(nproc) && \
    make install && \
    rm -rf /tmp/yosys

# Build nextpnr-ice40 (pinned release)
RUN git clone --recursive --depth 1 --branch nextpnr-0.7 https://github.com/YosysHQ/nextpnr.git /tmp/nextpnr && \
    cd /tmp/nextpnr && \
    cmake -DARCH=ice40 -DCMAKE_INSTALL_PREFIX=/usr/local -DICESTORM_INSTALL_PREFIX=/usr/local . && \
    make -j$(nproc) && \
    make install && \
    rm -rf /tmp/nextpnr

WORKDIR /workspace
