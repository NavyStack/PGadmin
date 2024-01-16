FROM node:latest AS git
RUN git clone https://github.com/pgadmin-org/pgadmin4.git

FROM node:latest AS app-builder

RUN apt update && apt install -y nasm

COPY --from=git /pgadmin4/web /pgadmin4/web
RUN rm -rf /pgadmin4/web/*.log \
           /pgadmin4/web/config_*.py \
           /pgadmin4/web/node_modules \
           /pgadmin4/web/regression \
           `find /pgadmin4/web -type d -name tests` \
           `find /pgadmin4/web -type f -name .DS_Store`

WORKDIR /pgadmin4/web

RUN export CPPFLAGS="-DPNG_ARM_NEON_OPT=0" && \
    yarn set version berry && \
    yarn set version 3 && \
    yarn install && \
    yarn run bundle \
    && rm -rf node_modules \
           yarn.lock \
           package.json \
           babel.cfg \
           webpack.* \
           jest.config.js \
           babel.* \
           ./pgadmin/static/js/generated/.cache \
           .[!.]*

FROM python:3.11-bookworm AS env-builder

COPY --from=git /pgadmin4/requirements.txt /
RUN apt update && apt install -y \
        build-essential \
        rustc \
        cargo \
        python3.11-dev \
        locales && \
    sed -i -e 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen && \
    dpkg-reconfigure --frontend=noninteractive locales && \
    python3 -m venv --system-site-packages --without-pip /venv && \
    /venv/bin/python3 -m pip install --no-cache-dir -r requirements.txt

FROM env-builder AS docs-builder

RUN /venv/bin/python3 -m pip install --no-cache-dir sphinx
RUN /venv/bin/python3 -m pip install --no-cache-dir sphinxcontrib-youtube

COPY --from=git /pgadmin4/docs /pgadmin4/docs
COPY --from=git /pgadmin4/web /pgadmin4/web
RUN rm -rf /pgadmin4/docs/en_US/_build
RUN LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 /venv/bin/sphinx-build /pgadmin4/docs/en_US /pgadmin4/docs/en_US/_build/html
RUN rm -rf /pgadmin4/docs/en_US/_build/html/.doctrees
RUN rm -rf /pgadmin4/docs/en_US/_build/html/_sources
RUN rm -rf /pgadmin4/docs/en_US/_build/html/_static/*.png


FROM node:latest AS tool-builder
COPY --from=postgres:12-bookworm /usr/bin/pg_dump /usr/bin/pg_dumpall /usr/bin/pg_restore /usr/bin/psql /usr/local/pgsql/pgsql-12/
COPY --from=postgres:13-bookworm /usr/bin/pg_dump /usr/bin/pg_dumpall /usr/bin/pg_restore /usr/bin/psql /usr/local/pgsql/pgsql-13/
COPY --from=postgres:14-bookworm /usr/bin/pg_dump /usr/bin/pg_dumpall /usr/bin/pg_restore /usr/bin/psql /usr/local/pgsql/pgsql-14/
COPY --from=postgres:15-bookworm /usr/bin/pg_dump /usr/bin/pg_dumpall /usr/bin/pg_restore /usr/bin/psql /usr/local/pgsql/pgsql-15/
COPY --from=postgres:16-bookworm /usr/bin/pg_dump /usr/bin/pg_dumpall /usr/bin/pg_restore /usr/bin/psql /usr/local/pgsql/pgsql-16/


FROM python:3.11-slim-bookworm as layer-cutter
ARG user=pgadmin
RUN groupadd --system --gid 1010 $user && \
    useradd --system --gid $user --no-create-home --home /nonexistent --comment "pgadmin user" --shell /bin/false --uid 1009 $user
COPY --from=env-builder --chown=$user:$user /venv /venv
COPY --from=tool-builder --chown=$user:$user /usr/local/pgsql /usr/local/
COPY --from=app-builder --chown=$user:$user /pgadmin4/web /pgadmin4
COPY --from=docs-builder --chown=$user:$user /pgadmin4/docs/en_US/_build/html/ /pgadmin4/docs
COPY --from=git --chown=$user:$user /pgadmin4/pkg/docker/run_pgadmin.py /pgadmin4
COPY --from=git --chown=$user:$user /pgadmin4/pkg/docker/gunicorn_config.py /pgadmin4
COPY --from=git --chown=$user:$user /pgadmin4/pkg/docker/entrypoint.sh /pgadmin4/entrypoint.sh
COPY --from=git /pgadmin4/LICENSE /pgadmin4/LICENSE
COPY --from=git /pgadmin4/DEPENDENCIES /pgadmin4/DEPENDENCIES

RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get -qq install \
        apt-utils \
        postfix \
        krb5-user \
        libjpeg62-turbo \
        sudo \
        tzdata \
        libedit2 \
        libldap-2.5-0 \
        libcap2-bin \
        libpq-dev && \
    /venv/bin/python3 -m pip install --no-cache-dir gunicorn==20.1.0 && \
    find . | grep -E "(/__pycache__$|\.pyc$|\.pyo$)" | xargs rm -rf && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* && \
    mkdir -p /var/lib/pgadmin && \
    chown pgadmin:pgadmin /var/lib/pgadmin && \
    touch /pgadmin4/config_distro.py && \
    chown pgadmin:pgadmin /pgadmin4/config_distro.py && \
    chmod g=u /var/lib/pgadmin /pgadmin4/config_distro.py /etc/passwd && \
    chown -R pgadmin:pgadmin /pgadmin4

FROM python:3.11-slim-bookworm as final
ARG user=pgadmin
RUN groupadd --system --gid 1010 $user && \
    useradd --system --gid $user --no-create-home --home /nonexistent --comment "pgadmin user" --shell /bin/false --uid 1009 $user

COPY --from=layer-cutter --chown=$user:$user /pgadmin4 /pgadmin4
COPY --from=tool-builder --chown=$user:$user /usr/local/pgsql /usr/local/
COPY --from=layer-cutter --chown=$user:$user /venv /venv
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get -qq install \
        apt-utils \
        postfix \
        krb5-user \
        libjpeg62-turbo \
        sudo \
        tzdata \
        libedit2 \
        libldap-2.5-0 \
        libcap2-bin \
        libpq-dev && \
    /venv/bin/python3 -m pip install --no-cache-dir gunicorn==20.1.0 && \
    find . | grep -E "(/__pycache__$|\.pyc$|\.pyo$)" | xargs rm -rf && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* && \
    mkdir -p /var/lib/pgadmin && \
    chown pgadmin:pgadmin /var/lib/pgadmin && \
    chmod g=u /var/lib/pgadmin /pgadmin4/config_distro.py /etc/passwd && \
    setcap CAP_NET_BIND_SERVICE=+eip /usr/bin/python3.11 && \
    echo "pgadmin ALL = NOPASSWD: /usr/sbin/postfix start" >> /etc/sudoers.d/postfix
    
USER pgadmin
WORKDIR /pgadmin4

VOLUME /var/lib/pgadmin
EXPOSE 80 443
ENTRYPOINT ["./entrypoint.sh"]