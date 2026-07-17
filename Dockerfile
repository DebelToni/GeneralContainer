# syntax=docker/dockerfile:1.7

FROM --platform=$BUILDPLATFORM golang:1.24-alpine AS s5cmd-builder
ARG TARGETOS
ARG TARGETARCH
ARG S5CMD_VERSION=v2.3.0
ENV CGO_ENABLED=0 \
    GOFLAGS="-buildvcs=false"
RUN apk add --no-cache git && \
    GOOS="$TARGETOS" GOARCH="$TARGETARCH" go install -ldflags="-s -w" "github.com/peak/s5cmd/v2@${S5CMD_VERSION}"

FROM nvidia/cuda:12.8.0-cudnn-devel-ubuntu22.04

ARG PYTORCH_INDEX_URL=https://download.pytorch.org/whl/cu128
ARG TORCH_VERSION=2.11.0
ARG TORCHVISION_VERSION=0.26.0
ARG JAX_VERSION=0.11.0
ARG FLAX_VERSION=0.12.7
ARG NODE_MAJOR=24

ENV DEBIAN_FRONTEND=noninteractive \
    VENV_DIR=/opt/venv \
    VIRTUAL_ENV=/opt/venv \
    PATH=/opt/venv/bin:/usr/local/nvidia/bin:/usr/local/cuda/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    PIP_NO_CACHE_DIR=1 \
    PROJECT_ROOT=/proj \
    DATA_DIR=/proj/data \
    GIT_REPO_URL="" \
    GIT_REPO_DIR=/proj/project \
    GIT_CLONE_DEPTH=1 \
    S3_URI="" \
    SYNC_DIRS="" \
    FORCE_SYNC=0 \
    S5CMD_NUMWORKERS=1024 \
    S5CMD_CONCURRENCY=20 \
    S3_ENTRYPOINT_URI="" \
    TS_AUTHKEY="" \
    TS_HOSTNAME="" \
    TS_TAGS=tag:gpu \
    TS_STATE_DIR=/var/lib/tailscale \
    TS_ACCEPT_DNS=false \
    TS_ENABLE_SSH=true \
    TS_EXTRA_ARGS=""

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update && apt-get install -y --no-install-recommends \
        software-properties-common gnupg \
        build-essential git openssh-client wget curl ca-certificates vim tmux pkg-config ripgrep \
        libssl-dev zlib1g-dev libbz2-dev libreadline-dev libsqlite3-dev \
        libffi-dev liblzma-dev tk-dev uuid-dev iproute2 procps \
    && add-apt-repository ppa:deadsnakes/ppa -y \
    && apt-get update && apt-get install -y --no-install-recommends \
        python3.13 python3.13-venv python3-pip \
    && rm -rf /var/lib/apt/lists/*

RUN python3.13 -m venv "$VENV_DIR" && \
    python -m pip install --upgrade pip && \
    python -m pip install \
        --index-url "$PYTORCH_INDEX_URL" \
        "torch==${TORCH_VERSION}" \
        "torchvision==${TORCHVISION_VERSION}" && \
    python -m pip install \
        "jax[cuda12]==${JAX_VERSION}" \
        "flax==${FLAX_VERSION}" \
        transformers datasets optax omegaconf kagglehub huggingface-hub && \
    python -m pip check

RUN curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - && \
    apt-get install -y --no-install-recommends nodejs && \
    node --version && npm --version && \
    rm -rf /var/lib/apt/lists/*

COPY --from=s5cmd-builder /go/bin/s5cmd /usr/local/bin/s5cmd
RUN s5cmd version && \
    curl -fsSL https://tailscale.com/install.sh | sh && \
    rm -rf /var/lib/apt/lists/* && \
    printf '%s\n' \
        'VIRTUAL_ENV=/opt/venv' \
        'PATH=/opt/venv/bin:/usr/local/nvidia/bin:/usr/local/cuda/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' \
        >> /etc/environment && \
    printf '%s\n' 'source /opt/venv/bin/activate || true' > /etc/profile.d/activate-venv.sh && \
    printf '%s\n' 'set -o vi' > /etc/profile.d/vi-mode.sh && \
    printf '%s\n' 'set -g mode-keys vi' > /etc/tmux.conf && \
    mkdir -p /proj /var/lib/tailscale

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

LABEL org.opencontainers.image.source="https://github.com/DebelToni/GeneralContainer" \
      org.opencontainers.image.description="Universal CUDA 12.8 JAX and PyTorch development container"

WORKDIR /proj
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD []
