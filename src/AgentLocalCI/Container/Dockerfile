FROM ubuntu:24.04@sha256:33ceb71981b602c1a7443a53469e4dba065f7503eab3078a2d7a57a2ab987517

ARG DEBIAN_FRONTEND=noninteractive
ARG TARGETARCH
ARG NODE_VERSION=22.22.0
ARG NODE_SHA256_AMD64=9aa8e9d2298ab68c600bd6fb86a6c13bce11a4eca1ba9b39d79fa021755d7c37
ARG NODE_SHA256_ARM64=1bf1eb9ee63ffc4e5d324c0b9b62cf4a289f44332dfef9607cea1a0d9596ba6f
ARG POWERSHELL_VERSION=7.6.4
ARG POWERSHELL_SHA256_AMD64=4471b5a36bfe86ec7af8525d36bb1cacba0128e7aac22d05cc064bc00e604721
ARG POWERSHELL_SHA256_ARM64=d4ef2382fa452f2ccbdb48a01adbbce9ed64954872123970c16be6d086d1224b
ARG ANDROID_TOOLS_VERSION=13114758
ARG ANDROID_TOOLS_SHA256=7ec965280a073311c339e571cd5de778b9975026cfcbe79f2b1cdcb1e15317ee

RUN apt-get update \
 && apt-get install --no-install-recommends -y \
      bash ca-certificates coreutils curl git gzip jq libicu74 libssl3 openjdk-17-jdk-headless \
      python3 tar unzip xz-utils zlib1g \
 && rm -rf /var/lib/apt/lists/* \
 && java_home="$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")" \
 && ln -s "${java_home}" /opt/java-home

RUN case "${TARGETARCH}" in \
      amd64) node_arch=x64; node_sha="${NODE_SHA256_AMD64}" ;; \
      arm64) node_arch=arm64; node_sha="${NODE_SHA256_ARM64}" ;; \
      *) echo "Unsupported Docker target architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
 && curl --fail --location --proto '=https' --tlsv1.2 \
      "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${node_arch}.tar.xz" \
      --output /tmp/node.tar.xz \
 && echo "${node_sha}  /tmp/node.tar.xz" | sha256sum --check --strict \
 && tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1 \
 && rm /tmp/node.tar.xz \
 && node --version | grep -Fx "v${NODE_VERSION}"

RUN case "${TARGETARCH}" in \
      amd64) powershell_arch=x64; powershell_sha="${POWERSHELL_SHA256_AMD64}" ;; \
      arm64) powershell_arch=arm64; powershell_sha="${POWERSHELL_SHA256_ARM64}" ;; \
      *) echo "Unsupported Docker target architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
 && mkdir -p /opt/microsoft/powershell/7 \
 && curl --fail --location --proto '=https' --tlsv1.2 \
      "https://github.com/PowerShell/PowerShell/releases/download/v${POWERSHELL_VERSION}/powershell-${POWERSHELL_VERSION}-linux-${powershell_arch}.tar.gz" \
      --output /tmp/powershell.tar.gz \
 && echo "${powershell_sha}  /tmp/powershell.tar.gz" | sha256sum --check --strict \
 && tar -xzf /tmp/powershell.tar.gz -C /opt/microsoft/powershell/7 \
 && chmod 0555 /opt/microsoft/powershell/7/pwsh \
 && ln -s /opt/microsoft/powershell/7/pwsh /usr/local/bin/pwsh \
 && rm /tmp/powershell.tar.gz

ENV ANDROID_SDK_ROOT=/opt/android-sdk \
    ANDROID_HOME=/opt/android-sdk \
    JAVA_HOME=/opt/java-home
RUN mkdir -p "${ANDROID_SDK_ROOT}/cmdline-tools" \
 && curl --fail --location --proto '=https' --tlsv1.2 \
      "https://dl.google.com/android/repository/commandlinetools-linux-${ANDROID_TOOLS_VERSION}_latest.zip" \
      --output /tmp/android-tools.zip \
 && echo "${ANDROID_TOOLS_SHA256}  /tmp/android-tools.zip" | sha256sum --check --strict \
 && unzip -q /tmp/android-tools.zip -d "${ANDROID_SDK_ROOT}/cmdline-tools" \
 && mv "${ANDROID_SDK_ROOT}/cmdline-tools/cmdline-tools" "${ANDROID_SDK_ROOT}/cmdline-tools/latest" \
 && rm /tmp/android-tools.zip \
 && yes | "${ANDROID_SDK_ROOT}/cmdline-tools/latest/bin/sdkmanager" --licenses >/dev/null \
 && "${ANDROID_SDK_ROOT}/cmdline-tools/latest/bin/sdkmanager" \
      'build-tools;35.0.0' 'build-tools;36.0.0' 'platform-tools' 'platforms;android-36'

RUN useradd --create-home --uid 10001 --shell /bin/bash ci \
 && install -d -o ci -g ci /workspace /evidence /npm-cache /gradle /from /to /opt/agentlocalci

COPY --chown=root:root runner.ps1 /opt/agentlocalci/runner.ps1
COPY --chown=root:root entrypoint.sh /opt/agentlocalci/entrypoint.sh
COPY --chown=root:root proxy.mjs /opt/agentlocalci/proxy.mjs
COPY --chown=root:root proxy-health.mjs /opt/agentlocalci/proxy-health.mjs
COPY --chown=root:root network-probe.mjs /opt/agentlocalci/network-probe.mjs
COPY --chown=root:root resolve-dependencies.gradle /opt/agentlocalci/resolve-dependencies.gradle
RUN chmod 0444 /opt/agentlocalci/runner.ps1 /opt/agentlocalci/proxy.mjs \
      /opt/agentlocalci/proxy-health.mjs /opt/agentlocalci/network-probe.mjs \
      /opt/agentlocalci/resolve-dependencies.gradle \
 && chmod 0555 /opt/agentlocalci/entrypoint.sh

LABEL io.agentlocalci.owner="agentlocalci" \
      io.agentlocalci.boundary="unprivileged-linux-container" \
      io.agentlocalci.node="22.22.0" \
      io.agentlocalci.jdk="17" \
      io.agentlocalci.android="36" \
      io.agentlocalci.arch="${TARGETARCH}"

ENV PATH="/opt/android-sdk/platform-tools:/opt/android-sdk/cmdline-tools/latest/bin:${PATH}" \
    HOME=/home/ci \
    CI=true \
    NEXT_TELEMETRY_DISABLED=1 \
    NPM_CONFIG_UPDATE_NOTIFIER=false

WORKDIR /workspace
USER 10001:10001
ENTRYPOINT ["/opt/agentlocalci/entrypoint.sh"]
