ARG PYTHON_VERSION=3.11.6
ARG DEBIAN_BASE=bookworm
FROM python:${PYTHON_VERSION}-slim-${DEBIAN_BASE} AS base

ARG WKHTMLTOPDF_VERSION=0.12.6.1-3
ARG WKHTMLTOPDF_DISTRO=bookworm
FROM base AS builder

RUN apt-get update && apt-get install -y git curl jq

# apps.json includes
ARG APPS_JSON_BASE64
RUN if [ -n "${APPS_JSON_BASE64}" ]; then \
    mkdir -p /opt/frappe && echo "${APPS_JSON_BASE64}" | base64 -d > /opt/frappe/apps.json && \
    chown -R root:root /opt/frappe; \
  fi

RUN useradd -ms /bin/bash cogniquaint && chown -R cogniquaint:cogniquaint /opt/frappe 2>/dev/null || true

USER cogniquaint

RUN --mount=type=secret,id=GH_PAT,dst=/root/.netrc \
    git config --global url."https://github.com/".insteadOf "https://github.com/" && \
    sh -c 'echo "machine github.com login x-oauth-basic password $(cat /root/.netrc)" > /root/.netrc' && \
    chmod 600 /root/.netrc && \
    mkdir -p /opt/frappe/apps && \
    if [ -f /opt/frappe/apps.json ]; then \
      jq -c ".[]" /opt/frappe/apps.json | while read -r line; do \
        url=$(echo "$line" | jq -r ".url") && \
        branch=$(echo "$line" | jq -r ".branch") && \
        repo_name=$(basename "$url" .git) && \
        git clone --branch "$branch" "$url" "/opt/frappe/apps/$repo_name" || echo "Failed to clone $url"; \
      done; \
    fi

