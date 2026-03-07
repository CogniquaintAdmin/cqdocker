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

RUN --mount=type=secret,id=GH_PAT2 \
    mkdir -p /opt/frappe/apps && \
    if [ -f /opt/frappe/apps.json ]; then \
      SECRET_TOKEN=$(cat /run/secrets/GH_PAT 2>/dev/null || true) && \
      if [ -n "$SECRET_TOKEN" ]; then \
        echo "Secret file found, token loaded: ${SECRET_TOKEN:0:10}..." && \
        git config --global url."https://${SECRET_TOKEN}:x-oauth-basic@github.com/".insteadOf "https://github.com/" && \
        echo "Git config updated successfully"; \
      else \
        echo "Warning: Secret file GH_PAT2 not found or empty"; \
      fi && \
      jq -c ".[]" /opt/frappe/apps.json | while read -r line; do \
        url=$(echo "$line" | jq -r ".url") && \
        branch=$(echo "$line" | jq -r ".branch") && \
        repo_name=$(basename "$url" .git) && \
        echo "Cloning $repo_name from $url (branch: $branch)" && \
        git clone --branch "$branch" "$url" "/opt/frappe/apps/$repo_name" || echo "Failed to clone $url"; \
      done; \
    else \
      echo "apps.json not found at /opt/frappe/apps.json"; \
    fi

