ARG BASE_IMAGE="ubuntu:20.04"
ARG TARGET_LIST="x86_64-softmmu,i386-softmmu,arm-softmmu,ppc-softmmu,mips-softmmu,mipsel-softmmu"

### BASE IMAGE
FROM $BASE_IMAGE as base
ARG BASE_IMAGE

# Copy dependencies lists into container. Note this
#  will rarely change so caching should still work well
COPY ./panda/dependencies/${BASE_IMAGE}*.txt /tmp/

# Base image just needs runtime dependencies
RUN [ -e /tmp/${BASE_IMAGE}_base.txt ] && \
    apt-get -qq update && \
    DEBIAN_FRONTEND=noninteractive apt-get -qq install -y --no-install-recommends $(cat /tmp/${BASE_IMAGE}_base.txt | grep -o '^[^#]*') && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*


### BUILD IMAGE - STAGE 2
FROM base AS builder
ARG BASE_IMAGE
ARG TARGET_LIST

RUN [ -e /tmp/${BASE_IMAGE}_build.txt ] && \
    apt-get -qq update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $(cat /tmp/${BASE_IMAGE}_build.txt | grep -o '^[^#]*') && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* && \
    python3 -m pip install --upgrade --no-cache-dir pip && \
    python3 -m pip install --upgrade --no-cache-dir setuptools wheel && \
    python3 -m pip install --upgrade --no-cache-dir pycparser protobuf cffi colorama && \
    curl https://sh.rustup.rs -sSf | sh -s -- -y

# Build and install panda
# Copy repo root directory to /panda, note we explicitly copy in .git directory
# Note .dockerignore file keeps us from copying things we don't need
COPY . /panda/
COPY .git /panda/

# Note we diable NUMA for docker builds because it causes make check to fail in docker
RUN git -C /panda submodule update --init dtc && \
    git -C /panda rev-parse HEAD > /usr/local/panda_commit_hash && \
    mkdir  /panda/build && cd /panda/build && \
    /panda/configure \
        --target-list="${TARGET_LIST}" \
        --prefix=/usr/local \
        --disable-numa \
        --enable-llvm && \
    make -C /panda/build -j "$(nproc)"

#### Develop setup: panda built + pypanda installed (in develop mode) + panda-rs installed - Stage 3
FROM builder as developer
ENV PANDA_PATH="/panda/build"
ENV PATH="/root/.cargo/bin:${PATH}"

RUN cd /panda/panda/python/core && \
    python3 setup.py develop &&  \
    ldconfig && \
    update-alternatives --install /usr/bin/python python /usr/bin/python3 10

# TODO: merge with above command?
RUN git -C /panda submodule update --init panda/rs-plugins && \
    /panda/panda/rs-plugins/install_plugins.sh
WORKDIR /panda/

#### Install PANDA + pypanda from builder - Stage 4
FROM builder as installer
RUN  make -C /panda/build install
# Install pypanda
RUN cd /panda/panda/python/core && \
    python3 setup.py install

### Copy files for panda+pypanda from installer  - Stage 5
FROM base as panda

COPY --from=installer /usr/local /usr/local

# Ensure runtime dependencies are installed for our libpanda objects and panda plugins
RUN ldconfig && \
    update-alternatives --install /usr/bin/python python /usr/bin/python3 10 && \
    if (ldd /usr/local/lib/python*/dist-packages/pandare/data/*-softmmu/libpanda-*.so | grep 'not found'); then exit 1; fi && \
    if (ldd /usr/local/lib/python*/dist-packages/pandare/data/*-softmmu/panda/plugins/*.so | grep 'not found'); then exit 1; fi

