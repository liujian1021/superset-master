#
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements...
#

######################################################################
# Node stage to deal with static asset construction
######################################################################
ARG PY_VER=3.11.13-slim-bookworm
ARG BUILDPLATFORM=${BUILDPLATFORM:-amd64}
ARG BUILD_TRANSLATIONS="false"

FROM --platform=${BUILDPLATFORM} node:20-bookworm-slim AS superset-node-ci
ARG BUILD_TRANSLATIONS
ENV BUILD_TRANSLATIONS=${BUILD_TRANSLATIONS}
ARG DEV_MODE="false"
ENV DEV_MODE=${DEV_MODE}

COPY docker/ /app/docker/
ARG NPM_BUILD_CMD="build"

RUN /app/docker/apt-install.sh build-essential python3 zstd

ENV BUILD_CMD=${NPM_BUILD_CMD} \
    PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=true

RUN /app/docker/frontend-mem-nag.sh

WORKDIR /app/superset-frontend

RUN mkdir -p /app/superset/static/assets \
             /app/superset/translations

RUN --mount=type=bind,source=./superset-frontend/package.json,target=./package.json \
    --mount=type=bind,source=./superset-frontend/package-lock.json,target=./package-lock.json \
    --mount=type=cache,id=npm-cache-root,target=/root/.cache \
    --mount=type=cache,id=npm-cache,target=/root/.npm \
    if [ "$DEV_MODE" = "false" ]; then \
        npm ci; \
    else \
        echo "Skipping 'npm ci' in dev mode"; \
    fi

COPY superset-frontend /app/superset-frontend

######################################################################
# superset-node is used for compiling frontend assets
######################################################################
FROM superset-node-ci AS superset-node

RUN --mount=type=cache,id=npm-build-cache,target=/root/.npm \
    if [ "$DEV_MODE" = "false" ]; then \
        echo "Running 'npm run ${BUILD_CMD}'"; \
        npm run ${BUILD_CMD}; \
    else \
        echo "Skipping 'npm run ${BUILD_CMD}' in dev mode"; \
    fi;

COPY superset/translations /app/superset/translations

RUN if [ "$BUILD_TRANSLATIONS" = "true" ]; then \
        npm run build-translation; \
    fi; \
    rm -rf /app/superset/translations/*/*/*.po; \
    rm -rf /app/superset/translations/*/*/*.mo;

######################################################################
# Base python layer
######################################################################
FROM python:${PY_VER} AS python-base

ARG SUPERSET_HOME="/app/superset_home"
ENV SUPERSET_HOME=${SUPERSET_HOME}

RUN mkdir -p $SUPERSET_HOME
RUN useradd --user-group -d ${SUPERSET_HOME} -m --no-log-init --shell /bin/bash superset \
    && chmod -R 1777 $SUPERSET_HOME \
    && chown -R superset:superset $SUPERSET_HOME

COPY --chmod=755 docker/*.sh /app/docker/

RUN pip install --no-cache-dir --upgrade uv
RUN uv venv /app/.venv
ENV PATH="/app/.venv/bin:${PATH}"

######################################################################
# Python translation compiler layer
######################################################################
FROM python-base AS python-translation-compiler

ARG BUILD_TRANSLATIONS
ENV BUILD_TRANSLATIONS=${BUILD_TRANSLATIONS}

COPY requirements/translations.txt requirements/
RUN --mount=type=cache,id=uv-translation-cache,target=/root/.cache/uv \
    . /app/.venv/bin/activate && /app/docker/pip-install.sh --requires-build-essential -r requirements/translations.txt

COPY superset/translations/ /app/translations_mo/
RUN if [ "$BUILD_TRANSLATIONS" = "true" ]; then \
        pybabel compile -d /app/translations_mo | true; \
    fi; \
    rm -f /app/translations_mo/*/*/*.po; \
    rm -f /app/translations_mo/*/*/*.json;

######################################################################
# Python APP common layer
######################################################################
FROM python-base AS python-common

ENV SUPERSET_HOME="/app/superset_home" \
    HOME="/app/superset_home" \
    SUPERSET_ENV="production" \
    FLASK_APP="superset.app:create_app()" \
    PYTHONPATH="/app/pythonpath" \
    SUPERSET_PORT="8088"

COPY --chmod=755 docker/entrypoints /app/docker/entrypoints

WORKDIR /app
RUN mkdir -p \
      ${PYTHONPATH} \
      superset/static \
      requirements \
      superset-frontend \
      apache_superset.egg-info \
      requirements \
    && touch superset/static/version_info.json

ARG INCLUDE_CHROMIUM="false"
ARG INCLUDE_FIREFOX="false"
RUN --mount=type=cache,id=uv-browser-cache,target=${SUPERSET_HOME}/.cache/uv \
    if [ "$INCLUDE_CHROMIUM" = "true" ] || [ "$INCLUDE_FIREFOX" = "true" ]; then \
        uv pip install playwright && \
        playwright install-deps && \
        if [ "$INCLUDE_CHROMIUM" = "true" ]; then playwright install chromium; fi && \
        if [ "$INCLUDE_FIREFOX" = "true" ]; then playwright install firefox; fi; \
    else \
        echo "Skipping browser installation"; \
    fi

COPY pyproject.toml setup.py MANIFEST.in README.md ./
COPY superset-frontend/package.json superset-frontend/
COPY scripts/check-env.py scripts/
COPY --chmod=755 ./docker/entrypoints/run-server.sh /usr/bin/

RUN /app/docker/apt-install.sh \
      curl \
      libsasl2-dev \
      libsasl2-modules-gssapi-mit \
      libpq-dev \
      libecpg-dev \
      libldap2-dev

COPY --from=superset-node /app/superset/static/assets superset/static/assets
COPY superset superset
RUN rm superset/translations/*/*/*.po

COPY --from=superset-node /app/superset/translations superset/translations
COPY --from=python-translation-compiler /app/translations_mo superset/translations

HEALTHCHECK CMD /app/docker/docker-healthcheck.sh
CMD ["/app/docker/entrypoints/run-server.sh"]
EXPOSE ${SUPERSET_PORT}

######################################################################
# Final lean image...
######################################################################
FROM python-common AS lean

COPY requirements/base.txt requirements/
COPY superset-core superset-core

RUN --mount=type=cache,id=uv-base-cache,target=${SUPERSET_HOME}/.cache/uv \
    /app/docker/pip-install.sh --requires-build-essential -r requirements/base.txt

RUN --mount=type=cache,id=uv-superset-cache,target=${SUPERSET_HOME}/.cache/uv \
    uv pip install -e .
RUN python -m compileall /app/superset

USER superset

######################################################################
# Dev image...
######################################################################
FROM python-common AS dev

RUN /app/docker/apt-install.sh \
    git \
    pkg-config \
    default-libmysqlclient-dev

COPY requirements/*.txt requirements/
COPY superset-core superset-core
COPY superset-cli superset-cli

RUN --mount=type=cache,id=uv-dev-cache,target=${SUPERSET_HOME}/.cache/uv \
    /app/docker/pip-install.sh --requires-build-essential -r requirements/development.txt

RUN --mount=type=cache,id=uv-dev-superset-cache,target=${SUPERSET_HOME}/.cache/uv \
    uv pip install -e .

RUN uv pip install .[postgres]
RUN python -m compileall /app/superset

USER superset

######################################################################
# CI image...
######################################################################
FROM lean AS ci
USER root
RUN uv pip install .[postgres]
USER superset
CMD ["/app/docker/entrypoints/docker-ci.sh"]
