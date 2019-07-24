ARG nginx_version=1.16.0
FROM nginx:${nginx_version} AS build

RUN set -x \
    && apt-get update \
    && apt-get install -y gcc make curl binutils \
        # Required for OpenSSL...
        perl libtext-template-perl libtest-http-server-simple-perl \
        # Required for NGINX...
        libpcre3-dev zlib1g-dev \
        # Required for ModSecurity...
        g++ autoconf libluajit-5.1-dev libtool libxml2-dev \
        git libcurl4-openssl-dev libgeoip-dev liblmdb-dev libpcre++-dev libyajl-dev

ARG openssl_version=1.1.1c
RUN set -x \
    && curl -fsSL "https://www.openssl.org/source/openssl-${openssl_version}.tar.gz" \
    |  tar -C /usr/local/src -xzvf- \
    && ln -sf /usr/local/src/openssl-${openssl_version} /usr/local/src/openssl \
    && cd /usr/local/src/openssl \
    && ./config \
    && make \
    && make test \
    && make install_sw \
    && ldconfig -v \
    && openssl version -a

ARG modsecurity_version=v3.0.3
RUN set -x \
    && git clone --depth 1 -b ${modsecurity_version} https://github.com/SpiderLabs/ModSecurity.git /usr/local/src/modsecurity \
    && cd /usr/local/src/modsecurity \
    && git submodule init \
    && git submodule update \
    && ./build.sh \
    && ./configure --prefix=/usr/local \
    && make \
    && make install

RUN set -x \
    && nginx_version=$(echo ${NGINX_VERSION} | sed 's/-.*//g') \
    && curl -fsSL "https://nginx.org/download/nginx-${nginx_version}.tar.gz" \
    |  tar -C /usr/local/src -xzvf- \
    && ln -sf /usr/local/src/nginx-${nginx_version} /usr/local/src/nginx \
    && cd /usr/local/src/nginx \
    && nginx_configure_args=$(nginx -V 2>&1 | grep 'configure arguments:' | awk -F 'configure arguments: ' '{print $2}') \
    && modified_configure_args=$(echo "${nginx_configure_args}" | sed -E 's| (--)|;\1|g' | tr -d \') \
    && IFS=';' \
    && ./configure ${modified_configure_args} \
    && make \
    && make install \
    && nginx -V 2>&1

RUN set -x \
    && strip --strip-unneeded \
        /usr/local/bin/openssl \
        /usr/local/bin/modsec-rules-check \
        /usr/local/lib/*.so* /usr/local/lib/*.a

FROM nginx:${nginx_version}

COPY --from=build /usr/local/bin/*      /usr/local/bin/
COPY --from=build /usr/local/include/*  /usr/local/include/
COPY --from=build /usr/local/lib/*      /usr/local/lib/

COPY --from=build /usr/sbin/nginx /usr/sbin/nginx

RUN set -x \
    && ldconfig -v 2>&1 \
    && openssl version -a \
    && nginx -V 2>&1 \
    && sed -i -E 's|listen\s+80|&80|g' /etc/nginx/conf.d/default.conf \
    && touch /var/run/nginx.pid \
    && mkdir -p /var/cache/nginx \
    && chown -R nginx:nginx /etc/nginx /var/log/nginx /var/cache/nginx /var/run/nginx.pid

USER nginx

WORKDIR /etc/nginx
