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
        # Force git to use the token as the password for any github.com request
        git config --global credential.helper 'store' && \
        echo "https://x-access-token:${SECRET_TOKEN}@github.com" > ~/.git-credentials && \
        echo "Git credentials configured."; \
      else \
        echo "Error: Secret GH_PAT not found"; exit 1; \
      fi && \
      jq -c ".[]" /opt/frappe/apps.json | while read -r line; do \
        url=$(echo "$line" | jq -r ".url") && \
        branch=$(echo "$line" | jq -r ".branch") && \
        repo_name=$(basename "$url" .git) && \
        echo "Cloning $repo_name from $url..." && \
        # GIT_TERMINAL_PROMPT=0 ensures it fails instead of hanging if token is wrong
        GIT_TERMINAL_PROMPT=0 git clone --depth 1 --branch "$branch" "$url" "/opt/frappe/apps/$repo_name" || { echo "Failed to clone $repo_name"; exit 1; }; \
      done; \
      # Cleanup sensitive data
      rm ~/.git-credentials && git config --global --unset credential.helper; \
    fi



# Stage 2: Final Image
FROM python:${PYTHON_VERSION}-slim-${DEBIAN_BASE} AS final

RUN useradd -ms /bin/bash -u 1000 cogniquaint
USER cogniquaint
WORKDIR /opt/frappe

# Copy only the cloned apps from the builder stage
COPY --from=builder --chown=cogniquaint:cogniquaint /opt/frappe/apps /opt/frappe/apps
