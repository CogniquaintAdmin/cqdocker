# --- STAGE 0: BASE ---
ARG PYTHON_VERSION=3.11.6
ARG DEBIAN_BASE=bookworm
FROM python:${PYTHON_VERSION}-slim-${DEBIAN_BASE} AS base

ARG WKHTMLTOPDF_VERSION=0.12.6.1-3
ARG WKHTMLTOPDF_DISTRO=bookworm
ARG NODE_VERSION=20.19.2
ENV NVM_DIR=/home/cogniquaint/.nvm
ENV PATH=${NVM_DIR}/versions/node/v${NODE_VERSION}/bin/:${PATH}

COPY docker/resources/nginx-template.conf /templates/nginx/frappe.conf.template
COPY docker/resources/nginx-entrypoint.sh /usr/local/bin/nginx-entrypoint.sh

RUN useradd -ms /bin/bash -u 1000 cogniquaint \
    && apt-get update \
    && apt-get install --no-install-recommends -y \
    curl git vim nginx gettext-base file libpango-1.0-0 libharfbuzz0b \
    libpangoft2-1.0-0 libpangocairo-1.0-0 restic gpg mariadb-client \
    less libpq-dev postgresql-client wait-for-it jq \
    && mkdir -p ${NVM_DIR} \
    && curl -o- https://raw.githubusercontent.com | bash \
    && . ${NVM_DIR}/nvm.sh \
    && nvm install ${NODE_VERSION} \
    && nvm use v${NODE_VERSION} \
    && npm install -g yarn \
    && nvm alias default v${NODE_VERSION} \
    && rm -rf ${NVM_DIR}/.cache \
    # Install wkhtmltopdf
    && if [ "$(uname -m)" = "aarch64" ]; then export ARCH=arm64; fi \
    && if [ "$(uname -m)" = "x86_64" ]; then export ARCH=amd64; fi \
    && downloaded_file=wkhtmltox_${WKHTMLTOPDF_VERSION}.${WKHTMLTOPDF_DISTRO}_${ARCH}.deb \
    && curl -sLO https://github.com \
    && apt-get install -y ./$downloaded_file \
    && rm $downloaded_file \
    && rm -rf /var/lib/apt/lists/* \
    && rm -fr /etc/nginx/sites-enabled/default \
    && pip3 install frappe-bench \
    # Nginx Permissions
    && sed -i '/user www-data/d' /etc/nginx/nginx.conf \
    && ln -sf /dev/stdout /var/log/nginx/access.log && ln -sf /dev/stderr /var/log/nginx/error.log \
    && touch /run/nginx.pid \
    && chown -R cogniquaint:cogniquaint /etc/nginx/conf.d /etc/nginx/nginx.conf /var/log/nginx /var/lib/nginx /run/nginx.pid \
    && chmod 755 /usr/local/bin/nginx-entrypoint.sh \
    && chmod 644 /templates/nginx/frappe.conf.template

# --- STAGE 1: BUILDER ---
FROM base AS builder

USER root
RUN apt-get update && apt-get install --no-install-recommends -y \
    wget libcairo2-dev libpango1.0-dev libjpeg-dev libgif-dev librsvg2-dev \
    libpq-dev libffi-dev liblcms2-dev libldap2-dev libmariadb-dev libsasl2-dev \
    libtiff5-dev libwebp-dev pkg-config redis-tools rlwrap tk8.6-dev cron \
    gcc build-essential libbz2-dev \
    && rm -rf /var/lib/apt/lists/*

# Handle apps.json
ARG APPS_JSON_BASE64
RUN if [ -n "${APPS_JSON_BASE64}" ]; then \
    mkdir -p /opt/frappe && echo "${APPS_JSON_BASE64}" | base64 -d > /opt/frappe/apps.json && \
    chown -R cogniquaint:cogniquaint /opt/frappe; \
  fi

USER cogniquaint
WORKDIR /home/cogniquaint

ARG GIT_BRANCH=version-16
ARG GIT_REPO_PATH=https://github.com

# Securely Mount PAT and Init Bench using Credential Store
RUN --mount=type=secret,id=GH_PAT,uid=1000 \
    if [ -f /run/secrets/GH_PAT ]; then \
        SECRET_TOKEN=$(cat /run/secrets/GH_PAT) && \
        git config --global credential.helper 'store' && \
        echo "https://x-access-token:${SECRET_TOKEN}@github.com" > ~/.git-credentials && \
        echo "Git credentials configured."; \
    fi && \
    export APP_INSTALL_ARGS="" && \
    if [ -f "/opt/frappe/apps.json" ]; then \
      export APP_INSTALL_ARGS="--apps_path=/opt/frappe/apps.json"; \
    fi && \
    # Initialize Bench
    bench init ${APP_INSTALL_ARGS} \
      --frappe-branch=${GIT_BRANCH} \
      --frappe-path=${GIT_REPO_PATH} \
      --no-procfile --no-backups --skip-redis-config-generation --verbose \
      /home/cogniquaint/cqbench && \
    # Post-init Cleanup
    cd /home/cogniquaint/cqbench && \
    echo "{}" > sites/common_site_config.json && \
    find apps -mindepth 1 -path "*/.git" | xargs rm -fr && \
    # Safety: Remove credentials
    rm -f ~/.git-credentials && git config --global --unset credential.helper

# --- STAGE 2: BACKEND (FINAL) ---
FROM base AS backend
USER cogniquaint
COPY --from=builder --chown=cogniquaint:cogniquaint /home/cogniquaint/cqbench /home/cogniquaint/cqbench
WORKDIR /home/cogniquaint/cqbench

VOLUME ["/home/cogniquaint/cqbench/sites", "/home/cogniquaint/cqbench/sites/assets", "/home/cogniquaint/cqbench/logs"]

CMD ["/home/cogniquaint/cqbench/env/bin/gunicorn", \
     "--chdir=/home/cogniquaint/cqbench/sites", \
     "--bind=0.0.0.0:8000", "--threads=4", "--workers=2", \
     "--worker-class=gthread", "--worker-tmp-dir=/dev/shm", \
     "--timeout=120", "--preload", "frappe.app:application"]
