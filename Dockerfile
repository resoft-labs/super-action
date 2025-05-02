# Use a base image that includes act, or install it manually
# Using a specific Ubuntu version for better dependency management
FROM ubuntu:24.04

# Install base dependencies + Python + pip + PyYAML + Docker + Git + jq + yq + curl + wget + Node.js
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    curl \
    jq \
    git \
    ca-certificates \
    wget \
    docker.io \
    python3 \
    python3-pip \
    python3-yaml \
    gnupg \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js (LTS) and npm (Needed for some actions run via act)
RUN curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - && \
    apt-get install -y nodejs && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# # Install yq (YAML processor)
# ARG YQ_VERSION=v4.45.1
# RUN curl https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64 -o /usr/local/bin/yq && \
#     chmod +x /usr/local/bin/yq

# Install nektos/act
RUN curl -s https://raw.githubusercontent.com/nektos/act/master/install.sh | bash -s -- -b /usr/local/bin

# Copy necessary files
COPY entrypoint.py /entrypoint.py
COPY parse_results.py /usr/local/bin/parse_results.py
COPY presets /presets

# Make scripts executable
RUN chmod +x /entrypoint.py
RUN chmod +x /usr/local/bin/parse_results.py

# Set the entrypoint to the Python script
ENTRYPOINT ["python3", "/entrypoint.py"]
