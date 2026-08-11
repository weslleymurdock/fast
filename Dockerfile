# syntax=docker/dockerfile:1.7

FROM debian:12-slim

ARG DEBIAN_FRONTEND=noninteractive
ARG ASTERISK_VERSION=22.10.1
ARG BCG729_VERSION=1.1.1
ARG ASTERISK_G72X_COMMIT=55a7b8246c8ad3f32e50a033529e5a52c11a5592
ARG OPENH264_VERSION=2.6.0
ARG OPUS_VERSION=1.5.2
ARG FREEPBX_REF=release/17.0

ENV LANG=C.UTF-8 LC_ALL=C.UTF-8 TZ=America/Sao_Paulo \
    ASTERISK_VERSION=${ASTERISK_VERSION} BCG729_VERSION=${BCG729_VERSION} \
    OPENH264_VERSION=${OPENH264_VERSION} OPUS_VERSION=${OPUS_VERSION} FREEPBX_REF=${FREEPBX_REF} \
    RTP_START=10000 RTP_END=20000 PJSIP_UDP_PORT=5060 PJSIP_TCP_PORT=5060 PJSIP_TLS_PORT=5061 \
    HTTP_PORT=80 HTTPS_PORT=443 DB_PORT=3306 DB_NAME=asterisk DB_CDR_NAME=asteriskcdrdb DB_USER=asterisk

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl wget git gnupg dirmngr xz-utils bzip2 unzip file patch \
    build-essential autoconf automake libtool pkg-config cmake meson ninja-build \
    libxml2-dev libncurses5-dev libsqlite3-dev uuid-dev libjansson-dev libssl-dev \
    libedit-dev libcurl4-openssl-dev libspeex-dev libspeexdsp-dev libogg-dev libvorbis-dev \
    libasound2-dev libsamplerate0-dev libsndfile1-dev libneon27-dev libiksemel-dev \
    libsnmp-dev libldap2-dev libunbound-dev liburiparser-dev libpq-dev unixodbc-dev \
    odbcinst libical-dev liblua5.4-dev libsystemd-dev libfftw3-dev libcodec2-dev \
    libgsm1-dev libmpg123-dev libspandsp-dev libpopt-dev libcap-dev libdb-dev \
    libmariadb-dev libmariadb-dev-compat mariadb-server mariadb-client \
    apache2 php8.2 php8.2-cli php8.2-common php8.2-mysql php8.2-curl php8.2-gd \
    php8.2-mbstring php8.2-xml php8.2-zip php8.2-bcmath php8.2-soap php8.2-intl \
    php8.2-ldap php8.2-imap nodejs npm composer rsync procps iproute2 net-tools \
    iputils-ping netcat-openbsd util-linux \
    && rm -rf /var/lib/apt/lists/*

RUN id asterisk >/dev/null 2>&1 || useradd --system --home /var/lib/asterisk --create-home --shell /usr/sbin/nologin asterisk

RUN mkdir -p /usr/src && cd /usr/src \
    && git clone --depth 1 --branch ${BCG729_VERSION} https://github.com/BelledonneCommunications/bcg729.git bcg729 \
    && cmake -S bcg729 -B bcg729/build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local \
    && cmake --build bcg729/build --parallel "$(nproc)" && cmake --install bcg729/build \
    && ldconfig && rm -rf bcg729

# Build Asterisk 22 LTS with pjproject bundled by Asterisk itself.
RUN mkdir -p /usr/src && cd /usr/src \
    && curl -fsSL https://downloads.asterisk.org/pub/telephony/asterisk/asterisk-${ASTERISK_VERSION}.tar.gz -o asterisk.tar.gz \
    && tar -xzf asterisk.tar.gz && cd asterisk-${ASTERISK_VERSION} \
    && contrib/scripts/install_prereq install \
    && ./configure --with-pjproject-bundled --with-jansson --with-ssl --with-srtp \
    && make menuselect.makeopts \
    && menuselect/menuselect --enable codec_opus --enable codec_h264 \
         --enable res_pjsip --enable res_pjsip_transport_websocket --enable chan_pjsip \
         --enable res_http_websocket --enable res_rtp_asterisk --enable res_srtp menuselect.makeopts || true \
    && make -j"$(nproc)" && make install && make samples && ldconfig \
    && cd / && rm -rf /usr/src/asterisk*

# Build the GPL codec module against the installed Asterisk 22 headers. The pinned
# upstream commit explicitly added Asterisk 22 support.
RUN mkdir -p /usr/src && cd /usr/src \
    && git clone --depth 1 https://github.com/arkadijs/asterisk-g72x.git asterisk-g72x \
    && cd asterisk-g72x && git checkout ${ASTERISK_G72X_COMMIT} \
    && ./autogen.sh \
    && ./configure --with-asterisk160 --with-bcg729 --with-asterisk-includes=/usr/include --prefix=/usr \
    && make -j"$(nproc)" && make install \
    && ldconfig && cd / && rm -rf /usr/src/asterisk-g72x

RUN mkdir -p /usr/src && cd /usr/src \
    && git clone --depth 1 --branch v${OPENH264_VERSION} https://github.com/cisco/openh264.git openh264 \
    && make -C openh264 -j"$(nproc)" && make -C openh264 PREFIX=/usr install \
    && ldconfig && rm -rf openh264

RUN mkdir -p /usr/src && cd /usr/src \
    && curl -fsSL https://github.com/xiph/opus/releases/download/v${OPUS_VERSION}/opus-${OPUS_VERSION}.tar.gz -o opus.tar.gz \
    && tar -xzf opus.tar.gz && cd opus-${OPUS_VERSION} \
    && ./configure --prefix=/usr --disable-doc && make -j"$(nproc)" && make install \
    && ldconfig && cd / && rm -rf /usr/src/opus*

RUN mkdir -p /usr/src/freepbx \
    && git clone --depth 1 --branch ${FREEPBX_REF} https://github.com/FreePBX/framework.git /usr/src/freepbx \
    && mkdir -p /var/www/html && rsync -a --delete /usr/src/freepbx/ /var/www/html/ \
    && chown -R asterisk:asterisk /var/www/html && rm -rf /usr/src/freepbx

RUN a2enmod rewrite headers expires proxy proxy_http ssl setenvif \
    && phpenmod mysqli curl mbstring xml zip gd intl bcmath soap ldap \
    && printf '%s\n' 'memory_limit=256M' 'upload_max_filesize=64M' 'post_max_size=64M' 'date.timezone=America/Sao_Paulo' > /etc/php/8.2/apache2/conf.d/99-freepbx.ini \
    && printf '%s\n' 'ServerName localhost' 'DocumentRoot /var/www/html' '<Directory /var/www/html>' '    AllowOverride All' '    Require all granted' '</Directory>' > /etc/apache2/sites-available/freepbx.conf \
    && a2dissite 000-default.conf && a2ensite freepbx.conf \
    && sed -i 's/^export APACHE_RUN_USER=.*/export APACHE_RUN_USER=asterisk/' /etc/apache2/envvars \
    && sed -i 's/^export APACHE_RUN_GROUP=.*/export APACHE_RUN_GROUP=asterisk/' /etc/apache2/envvars

COPY docker/entrypoint.sh /usr/local/bin/fast-freepbx-entrypoint
COPY docker/healthcheck.sh /usr/local/bin/fast-freepbx-healthcheck
COPY docker/asterisk-rtp.conf /etc/asterisk/rtp_custom.conf
RUN chmod +x /usr/local/bin/fast-freepbx-entrypoint /usr/local/bin/fast-freepbx-healthcheck \
    && mkdir -p /etc/asterisk /var/lib/asterisk /var/spool/asterisk /var/log/asterisk /var/log/pbx \
    && chown -R asterisk:asterisk /etc/asterisk /var/lib/asterisk /var/spool/asterisk /var/log/asterisk || true

VOLUME ["/etc/asterisk", "/var/lib/asterisk", "/var/spool/asterisk", "/var/log/asterisk", "/var/www/html", "/var/lib/mysql"]
EXPOSE 5060/udp 5060/tcp 5061/tcp 80/tcp 443/tcp 8088/tcp
EXPOSE 10000-20000/udp
HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=5 CMD ["/usr/local/bin/fast-freepbx-healthcheck"]
STOPSIGNAL SIGTERM
ENTRYPOINT ["/usr/local/bin/fast-freepbx-entrypoint"]
