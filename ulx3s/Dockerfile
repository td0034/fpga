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

# Build Project Trellis (ECP5 database — required by nextpnr-ecp5)
RUN git clone --recursive https://github.com/YosysHQ/prjtrellis.git /tmp/prjtrellis && \
    cd /tmp/prjtrellis/libtrellis && \
    cmake -DCMAKE_INSTALL_PREFIX=/usr/local . && \
    make -j$(nproc) && \
    make install && \
    rm -rf /tmp/prjtrellis

# Build Yosys (pinned release)
RUN git clone --depth 1 --branch yosys-0.44 --recursive https://github.com/YosysHQ/yosys.git /tmp/yosys && \
    cd /tmp/yosys && \
    make -j$(nproc) && \
    make install && \
    rm -rf /tmp/yosys

# Build nextpnr-ecp5 (pinned release)
# Limited to -j2: ECP5 chipdb + pybindings are memory-hungry and OOM with full parallelism
RUN git clone --recursive --depth 1 --branch nextpnr-0.7 https://github.com/YosysHQ/nextpnr.git /tmp/nextpnr && \
    cd /tmp/nextpnr && \
    cmake -DARCH=ecp5 -DCMAKE_INSTALL_PREFIX=/usr/local -DTRELLIS_INSTALL_PREFIX=/usr/local . && \
    make -j2 && \
    make install && \
    rm -rf /tmp/nextpnr

WORKDIR /workspace
