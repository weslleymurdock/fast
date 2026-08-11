# syntax=docker/dockerfile:1.7

ARG ASTERISK_VERSION=22.10.1
ARG ASTERISK_REPOSITORY=https://github.com/asterisk/asterisk.git
ARG PJSIP_VERSION=2.17
ARG PJSIP_REPOSITORY=https://github.com/pjsip/pjproject.git
ARG OPENSSL_VERSION=1_1_1s
ARG OPENSSL_REPOSITORY=https://github.com/openssl/openssl.git
ARG BCG729_VERSION=1.1.1
ARG BCG729_REPOSITORY=https://github.com/BelledonneCommunications/bcg729.git
ARG OPENH264_VERSION=2.3.0
ARG OPENH264_REPOSITORY=https://github.com/cisco/openh264.git
ARG OPUS_VERSION=1.4.0
ARG OPUS_REPOSITORY=https://github.com/xiph/opus.git
ARG ASTERISK_G72X_COMMIT=55a7b8246c8ad3f32e50a033529e5a52c11a5592
ARG ASTERISK_G72X_REPOSITORY=https://github.com/arkadijs/asterisk-g72x.git
ARG FREEPBX_REF=release/17.0
ARG FREEPBX_REPOSITORY=https://github.com/FreePBX/framework.git

FROM debian:12-slim AS build-base
ARG DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl wget git xz-utils bzip2 unzip file patch \
    build-essential autoconf automake libtool pkg-config cmake meson ninja-build \
    libxml2-dev libncurses5-dev libsqlite3-dev uuid-dev libjansson-dev \
    libedit-dev libcurl4-openssl-dev libspeex-dev libspeexdsp-dev libogg-dev libvorbis-dev \
    libasound2-dev libsamplerate0-dev libsndfile1-dev libneon27-dev libiksemel-dev \
    libsnmp-dev libldap2-dev libunbound-dev liburiparser-dev libpq-dev unixodbc-dev \
    odbcinst libical-dev liblua5.4-dev libsystemd-dev libfftw3-dev libcodec2-dev \
    libgsm1-dev libmpg123-dev libspandsp-dev libpopt-dev libcap-dev libdb-dev \
    libmariadb-dev libmariadb-dev-compat libsrtp2-dev \
    && rm -rf /var/lib/apt/lists/*

FROM build-base AS openssl
ARG OPENSSL_VERSION
ARG OPENSSL_REPOSITORY
RUN git clone --branch main --single-branch --no-tags "${OPENSSL_REPOSITORY}" /usr/src/openssl \
    && cd /usr/src/openssl \
    && git fetch --tags --force \
    && git checkout --detach "openssl-${OPENSSL_VERSION}" \
    && ./config --prefix=/opt/artifact --openssldir=/opt/artifact/ssl shared no-tests \
    && make -j"$(nproc)" \
    && make install_sw

FROM build-base AS pjproject
ARG PJSIP_VERSION
ARG PJSIP_REPOSITORY
COPY --from=openssl /opt/artifact/ /opt/openssl/
ENV PKG_CONFIG_PATH="/opt/openssl/lib/pkgconfig"
ENV CPPFLAGS="-I/opt/openssl/include"
ENV LDFLAGS="-L/opt/openssl/lib"
RUN git clone --branch main --single-branch --no-tags "${PJSIP_REPOSITORY}" /usr/src/pjproject \
    && cd /usr/src/pjproject \
    && git fetch --tags --force \
    && git checkout --detach "${PJSIP_VERSION}" \
    && ./configure --prefix=/opt/artifact --with-ssl=/opt/openssl --disable-sound --disable-video \
    && make dep \
    && make -j"$(nproc)" \
    && make install

FROM build-base AS codec-bcg729
ARG BCG729_VERSION
ARG BCG729_REPOSITORY
RUN git clone --branch main --single-branch --no-tags "${BCG729_REPOSITORY}" /usr/src/bcg729 \
    && cd /usr/src/bcg729 \
    && git fetch --tags --force \
    && git checkout --detach "${BCG729_VERSION}" \
    && cmake -S /usr/src/bcg729 -B /usr/src/bcg729/build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/opt/artifact \
    && cmake --build /usr/src/bcg729/build --parallel "$(nproc)" \
    && cmake --install /usr/src/bcg729/build

FROM build-base AS codec-opus
ARG OPUS_VERSION
ARG OPUS_REPOSITORY
RUN git clone --branch main --single-branch --no-tags "${OPUS_REPOSITORY}" /usr/src/opus \
    && cd /usr/src/opus \
    && git fetch --tags --force \
    && git checkout --detach "v${OPUS_VERSION}" \
    && ./autogen.sh \
    && ./configure --prefix=/opt/artifact --disable-doc \
    && make -j"$(nproc)" \
    && make install

FROM build-base AS codec-openh264
ARG OPENH264_VERSION
ARG OPENH264_REPOSITORY
RUN git clone --branch main --single-branch --no-tags "${OPENH264_REPOSITORY}" /usr/src/openh264 \
    && cd /usr/src/openh264 \
    && git fetch --tags --force \
    && git checkout --detach "v${OPENH264_VERSION}" \
    && make -j"$(nproc)" \
    && make PREFIX=/opt/artifact install

FROM build-base AS asterisk
ARG ASTERISK_VERSION
ARG ASTERISK_REPOSITORY
COPY --from=openssl /opt/artifact/ /opt/dependencies/
COPY --from=pjproject /opt/artifact/ /opt/dependencies/
COPY --from=codec-bcg729 /opt/artifact/ /opt/dependencies/
COPY --from=codec-opus /opt/artifact/ /opt/dependencies/
COPY --from=codec-openh264 /opt/artifact/ /opt/dependencies/
ENV PKG_CONFIG_PATH="/opt/dependencies/lib/pkgconfig:/opt/dependencies/lib64/pkgconfig"
ENV CPPFLAGS="-I/opt/dependencies/include"
ENV LDFLAGS="-L/opt/dependencies/lib -L/opt/dependencies/lib64"
ENV LD_LIBRARY_PATH="/opt/dependencies/lib:/opt/dependencies/lib64"
RUN cp -a /opt/dependencies/. /usr/local/ \
    && ldconfig \
    && git clone --branch main --single-branch --no-tags "${ASTERISK_REPOSITORY}" /usr/src/asterisk \
    && cd /usr/src/asterisk \
    && git fetch --tags --force \
    && git checkout --detach "${ASTERISK_VERSION}" \
    && contrib/scripts/install_prereq install \
    && ./configure --with-pjproject=/usr/local --with-jansson --with-ssl=/usr/local --with-srtp \
    && make menuselect.makeopts \
    && menuselect/menuselect --enable codec_opus --enable codec_h264 --enable res_pjsip --enable res_pjsip_transport_websocket --enable chan_pjsip --enable res_http_websocket --enable res_rtp_asterisk --enable res_srtp menuselect.makeopts \
    && make -j"$(nproc)" VERBOSE=1 \
    && make install \
    && make samples \
    && ldconfig

FROM build-base AS codec-g729
ARG ASTERISK_G72X_COMMIT
ARG ASTERISK_G72X_REPOSITORY
COPY --from=codec-bcg729 /opt/artifact/ /opt/dependencies/
COPY --from=asterisk /usr/local/ /usr/local/
COPY --from=asterisk /etc/asterisk/ /etc/asterisk/
ENV PKG_CONFIG_PATH="/opt/dependencies/lib/pkgconfig:/opt/dependencies/lib64/pkgconfig"
ENV LD_LIBRARY_PATH="/opt/dependencies/lib:/opt/dependencies/lib64:/usr/local/lib"
RUN cp -a /opt/dependencies/. /usr/local/ \
    && ldconfig \
    && git clone --branch main --single-branch --no-tags "${ASTERISK_G72X_REPOSITORY}" /usr/src/asterisk-g72x \
    && cd /usr/src/asterisk-g72x \
    && git fetch --all --force \
    && git checkout --detach "${ASTERISK_G72X_COMMIT}" \
    && ./autogen.sh \
    && ./configure --with-asterisk160 --with-bcg729 --with-asterisk-includes=/usr/include --prefix=/usr \
    && make -j"$(nproc)" \
    && make DESTDIR=/opt/artifact install

FROM debian:12-slim AS freepbx
ARG FREEPBX_REF
ARG FREEPBX_REPOSITORY
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates git rsync \
    && git clone --branch main --single-branch --no-tags "${FREEPBX_REPOSITORY}" /opt/freepbx \
    && cd /opt/freepbx \
    && git fetch --all --force \
    && git checkout --detach "${FREEPBX_REF}" \
    && rm -rf /var/lib/apt/lists/*

FROM debian:12-slim AS final
ARG DEBIAN_FRONTEND=noninteractive
ARG ASTERISK_VERSION
ARG PJSIP_VERSION
ARG OPENSSL_VERSION
ARG BCG729_VERSION
ARG OPENH264_VERSION
ARG OPUS_VERSION
ARG FREEPBX_REF
ENV LANG=C.UTF-8 LC_ALL=C.UTF-8 TZ=America/Sao_Paulo \
    ASTERISK_VERSION=${ASTERISK_VERSION} PJSIP_VERSION=${PJSIP_VERSION} OPENSSL_VERSION=${OPENSSL_VERSION} \
    BCG729_VERSION=${BCG729_VERSION} OPENH264_VERSION=${OPENH264_VERSION} OPUS_VERSION=${OPUS_VERSION} FREEPBX_REF=${FREEPBX_REF} \
    RTP_START=10000 RTP_END=20000 PJSIP_UDP_PORT=5060 PJSIP_TCP_PORT=5060 PJSIP_TLS_PORT=5061 \
    HTTP_PORT=80 HTTPS_PORT=443 DB_PORT=3306 DB_NAME=asterisk DB_CDR_NAME=asteriskcdrdb DB_USER=asterisk
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl wget mariadb-server mariadb-client apache2 \
    php8.2 php8.2-cli php8.2-common php8.2-mysql php8.2-curl php8.2-gd php8.2-mbstring \
    php8.2-xml php8.2-zip php8.2-bcmath php8.2-soap php8.2-intl php8.2-ldap php8.2-imap \
    nodejs npm composer rsync procps iproute2 net-tools iputils-ping netcat-openbsd util-linux \
    libxml2 libncurses6 libsqlite3-0 libuuid1 libjansson4 libedit2 libcurl4 libspeex1 \
    libspeexdsp1 libogg0 libvorbis0a libasound2 libsamplerate0 libsndfile1 libneon27 \
    libsnmp40 libldap-2.5-0 libunbound8 liburiparser1 libpq5 libodbc2 libical3 liblua5.4-0 \
    libsystemd0 libfftw3-double3 libcodec2-1.0 libgsm1 libmpg123-0 libspandsp2 libpopt0 \
    libcap2 libdb5.3 libmariadb3 libsrtp2-1 libopus0 \
    && rm -rf /var/lib/apt/lists/*
RUN id asterisk >/dev/null 2>&1 || useradd --system --home /var/lib/asterisk --create-home --shell /usr/sbin/nologin asterisk
COPY --from=asterisk /usr/local/ /usr/local/
COPY --from=asterisk /usr/sbin/ /usr/sbin/
COPY --from=asterisk /etc/asterisk/ /etc/asterisk/
COPY --from=asterisk /var/lib/asterisk/ /var/lib/asterisk/
COPY --from=asterisk /var/spool/asterisk/ /var/spool/asterisk/
COPY --from=asterisk /var/log/asterisk/ /var/log/asterisk/
COPY --from=codec-g729 /opt/artifact/ /
COPY --from=freepbx /opt/freepbx/ /var/www/html/
COPY docker/entrypoint.sh /usr/local/bin/fast-freepbx-entrypoint
COPY docker/healthcheck.sh /usr/local/bin/fast-freepbx-healthcheck
COPY docker/asterisk-rtp.conf /etc/asterisk/rtp_custom.conf
RUN ldconfig && a2enmod rewrite headers expires proxy proxy_http ssl setenvif \
    && phpenmod mysqli curl mbstring xml zip gd intl bcmath soap ldap \
    && printf '%s\n' 'memory_limit=256M' 'upload_max_filesize=64M' 'post_max_size=64M' 'date.timezone=America/Sao_Paulo' > /etc/php/8.2/apache2/conf.d/99-freepbx.ini \
    && printf '%s\n' 'ServerName localhost' 'DocumentRoot /var/www/html' '<Directory /var/www/html>' '    AllowOverride All' '    Require all granted' '</Directory>' > /etc/apache2/sites-available/freepbx.conf \
    && a2dissite 000-default.conf && a2ensite freepbx.conf \
    && sed -i 's/^export APACHE_RUN_USER=.*/export APACHE_RUN_USER=asterisk/' /etc/apache2/envvars \
    && sed -i 's/^export APACHE_RUN_GROUP=.*/export APACHE_RUN_GROUP=asterisk/' /etc/apache2/envvars \
    && mkdir -p /etc/asterisk /var/lib/asterisk /var/spool/asterisk /var/log/asterisk /var/log/pbx \
    && chown -R asterisk:asterisk /etc/asterisk /var/lib/asterisk /var/spool/asterisk /var/log/asterisk /var/www/html \
    && chmod +x /usr/local/bin/fast-freepbx-entrypoint /usr/local/bin/fast-freepbx-healthcheck
VOLUME ["/etc/asterisk", "/var/lib/asterisk", "/var/spool/asterisk", "/var/log/asterisk", "/var/www/html", "/var/lib/mysql"]
EXPOSE 5060/udp 5060/tcp 5061/tcp 80/tcp 443/tcp 8088/tcp 10000-20000/udp
HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=5 CMD ["/usr/local/bin/fast-freepbx-healthcheck"]
STOPSIGNAL SIGTERM
ENTRYPOINT ["/usr/local/bin/fast-freepbx-entrypoint"]
