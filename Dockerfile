FROM ubuntu:24.10

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    curl \
    jq \
    git \
    ca-certificates \
    wget \
    docker.io \
    && rm -rf /var/lib/apt/lists/*

# Install yq (YAML processor)
ARG YQ_VERSION=v4.45.1
RUN apt-get update && apt-get install -y --no-install-recommends curl && \
    ARCH=$(dpkg --print-architecture) && \
    case "${ARCH}" in \
    amd64) YQ_ARCH="amd64" ;; \
    arm64) YQ_ARCH="arm64" ;; \
    *) echo "::error::Unsupported architecture: ${ARCH}"; exit 1 ;; \
    esac && \
    echo "Detected architecture: ${ARCH}, using yq suffix: ${YQ_ARCH}" && \
    wget https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${YQ_ARCH} -O /usr/local/bin/yq && \
    chmod +x /usr/local/bin/yq && \
    # apt-get purge -y --auto-remove curl && \
    rm -rf /var/lib/apt/lists/*

# Install nektos/act
RUN curl -s https://raw.githubusercontent.com/nektos/act/master/install.sh | bash -s -- -b /usr/local/bin

COPY entrypoint.sh /entrypoint.sh
COPY presets /presets
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
