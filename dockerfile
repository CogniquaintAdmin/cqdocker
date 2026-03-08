ARG PYTHON_VERSION=3.11.6
ARG DEBIAN_BASE=bookworm

# Stage 1: Builder
FROM python:${PYTHON_VERSION}-slim-${DEBIAN_BASE} AS builder

RUN apt-get update && apt-get install -y git curl jq

# Handle apps.json
ARG APPS_JSON_BASE64
RUN if [ -n "${APPS_JSON_BASE64}" ]; then \
    mkdir -p /opt/frappe && echo "${APPS_JSON_BASE64}" | base64 -d > /opt/frappe/apps.json; \
  fi

# Create user with explicit UID to match secret mounting
RUN useradd -ms /bin/bash -u 1000 cogniquaint
RUN chown -R cogniquaint:cogniquaint /opt/frappe

USER cogniquaint
WORKDIR /opt/frappe

# Mount secret with UID/GID 1000 so cogniquaint can read it
RUN --mount=type=secret,id=GH_PAT,uid=1000,gid=1000 \
    mkdir -p /opt/frappe/apps && \
    if [ -f /opt/frappe/apps.json ]; then \
      if [ -f /run/secrets/GH_PAT ]; then \
        SECRET_TOKEN=$(cat /run/secrets/GH_PAT) && \
        git config --global url."https://${SECRET_TOKEN}:x-oauth-basic@://github.com".insteadOf "https://://github.com" && \
        echo "Git configuration set with token."; \
      else \
        echo "Error: Secret GH_PAT not found at /run/secrets/GH_PAT"; exit 1; \
      fi && \
      jq -c ".[]" /opt/frappe/apps.json | while read -r line; do \
        url=$(echo "$line" | jq -r ".url") && \
        branch=$(echo "$line" | jq -r ".branch") && \
        repo_name=$(basename "$url" .git) && \
        echo "Cloning $repo_name..." && \
        git clone --depth 1 --branch "$branch" "$url" "/opt/frappe/apps/$repo_name"; \
      done; \
      # Cleanup git config to ensure no tokens remain in this layer
      git config --global --unset url."https://${SECRET_TOKEN}:x-oauth-basic@://github.com".insteadOf; \
    else \
      echo "apps.json not found, skipping clone."; \
    fi

# Stage 2: Final Image
FROM python:${PYTHON_VERSION}-slim-${DEBIAN_BASE} AS final

RUN useradd -ms /bin/bash -u 1000 cogniquaint
USER cogniquaint
WORKDIR /opt/frappe

# Copy only the cloned apps from the builder stage
COPY --from=builder --chown=cogniquaint:cogniquaint /opt/frappe/apps /opt/frappe/apps
