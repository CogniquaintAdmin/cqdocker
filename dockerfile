ARG PYTHON_VERSION=3.11.6
ARG DEBIAN_BASE=bookworm
FROM python:${PYTHON_VERSION}-slim-${DEBIAN_BASE} AS base

ARG WKHTMLTOPDF_VERSION=0.12.6.1-3
ARG WKHTMLTOPDF_DISTRO=bookworm
FROM base AS builder

RUN apt-get update && apt-get install -y git curl

# apps.json includes
ARG APPS_JSON_BASE64
RUN if [ -n "${APPS_JSON_BASE64}" ]; then \
    mkdir /opt/frappe && echo "${APPS_JSON_BASE64}" | base64 -d > /opt/frappe/apps.json; \
  fi

USER cogniquaint

RUN --mount=type=secret,id=git_token \
    if [ -s /run/secrets/git_token ]; then \
      export GIT_TOKEN=$(cat /run/secrets/git_token) && \
      git config --global url."https://${GIT_TOKEN}@github.com/".insteadOf "https://github.com/"; \
    fi && \
    mkdir -p /opt/frappe/apps && \
    if [ -f /opt/frappe/apps.json ]; then \
      jq -r '.[] | "\(.url) \(.branch)"' /opt/frappe/apps.json | while read url branch; do \
        repo_name=$(basename "$url" .git) && \
        git clone --branch "$branch" "$url" "/opt/frappe/apps/$repo_name" || echo "Failed to clone $url"; \
      done; \
    fi
