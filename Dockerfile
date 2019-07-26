ARG nginx_version=1.16.0
FROM nginx:${nginx_version} AS build

SHELL ["bash", "-c"]

RUN set -x \
    && apt-get update \
    && apt-get install -y gcc make curl binutils \
        # Required for OpenSSL...
        perl libtext-template-perl libtest-http-server-simple-perl \
        # Required for ModSecurity...
        g++ autoconf libtool libxml2-dev \
        git libcurl4-openssl-dev libgeoip-dev liblmdb-dev libpcre++-dev libyajl-dev \
        # Required for NGINX...
        libpcre3-dev zlib1g-dev \
        # Required for some NGINX modules
        libxslt1.1 libxslt1-dev

ARG openssl_version=1.1.1c
RUN set -x \
    && curl -fsSL "https://www.openssl.org/source/openssl-${openssl_version}.tar.gz" \
    |  tar -C /usr/local/src -xzvf- \
    && ln -sf /usr/local/src/openssl-${openssl_version} /usr/local/src/openssl \
    && cd /usr/local/src/openssl \
    && ./config \
    && make \
    && make test \
    && make install \
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

ARG luajit2_version=v2.1-20190626
RUN set -x \
    && curl -fsSL "https://github.com/openresty/luajit2/archive/${luajit2_version}.tar.gz" \
    |  tar -C /usr/local/src -xzvf- \
    && ln -sf /usr/local/src/luajit2-${luajit2_version#v} /usr/local/src/luajit2 \
    && cd /usr/local/src/luajit2 \
    && make \
    && make install \
    && ldconfig -v \
    && ln -sf /usr/local/include/luajit* /usr/local/include/luajit \
    && luajit -v \
    && ldconfig -v

ENV LUA_VERSION=5.1 \
    LUAJIT_LIB=/usr/local/lib \
    LUAJIT_INC=/usr/local/include/luajit

ARG resty_lrucache_version=v0.09
RUN set -x \
    && curl -fsSL "https://github.com/openresty/lua-resty-lrucache/archive/${resty_lrucache_version}.tar.gz" \
    |  tar -C /usr/local/src -xzvf- \
    && ln -sf /usr/local/src/lua-resty-lrucache-${resty_lrucache_version#v} /usr/local/src/lua-resty-lrucache \
    && cd /usr/local/src/lua-resty-lrucache \
    && make install

ARG resty_core_version=v0.1.17
RUN set -x \
    && curl -fsSL "https://github.com/openresty/lua-resty-core/archive/${resty_core_version}.tar.gz" \
    |  tar -C /usr/local/src -xzvf- \
    && ln -sf /usr/local/src/lua-resty-core-${resty_core_version#v} /usr/local/src/lua-resty-core \
    && cd /usr/local/src/lua-resty-core \
    && make install

ARG resty

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

ARG modules
RUN set -x \
    && \
    if [[ -z "${modules}" ]]; then \
      echo "Skipping dynamic module building since there are no modules provided..."; \
      exit 0; \
    fi \
    && apt-get install -y  \
    && cd /usr/local/src/nginx \
    && configure_args=$(nginx -V 2>&1 | grep "configure arguments:" | awk -F 'configure arguments:' '{print $2}') \
    && IFS=','; \
    for module in ${modules}; do \
      module_repo=$(echo $module | sed -E 's@^(((https?|git)://)?[^:]+).*@\1@g'); \
      module_tag=$(echo $module | sed -E 's@^(((https?|git)://)?[^:]+):?([^:/]*)@\4@g'); \
      dirname=$(echo "${module_repo}" | sed -E 's@^.*/|\..*$@@g'); \
      git clone --depth 1 "${module_repo}"; \
      cd ${dirname}; \
      git fetch --tags; \
      if [[ -n "${module_tag}" ]]; then \
        if [[ "${module_tag}" =~ ^(pr-[0-9]+.*)$ ]]; then \
          pr_numbers="${BASH_REMATCH[1]//pr-/}"; \
          IFS=';'; \
            for pr_number in ${pr_numbers}; do \
              git fetch origin "pull/${pr_number}/head:pr-${pr_number}"; \
              git merge --no-commit pr-${pr_number} master; \
            done; \
          IFS=','; \
        else \
          git checkout "${module_tag}"; \
        fi; \
      fi; \
      cd ..; \
      configure_args="${configure_args} --add-dynamic-module=./${dirname}"; \
    done \
    && unset IFS \
    && eval ./configure ${configure_args} \
    && make modules \
    && cp objs/*.so /usr/lib/nginx/modules/

RUN set -x \
    && strip --strip-unneeded \
        /usr/local/bin/openssl \
        /usr/local/bin/modsec-rules-check \
        /usr/local/lib/*.so* /usr/local/lib/*.a \
        /usr/lib/nginx/modules/*.so*

FROM nginx:${nginx_version}

COPY --from=build /usr/local/bin        /usr/local/bin
COPY --from=build /usr/local/include    /usr/local/include
COPY --from=build /usr/local/lib        /usr/local/lib
COPY --from=build /usr/local/share/lua* /usr/local/share/
COPY --from=build /usr/local/ssl        /usr/local/ssl

COPY --from=build /usr/sbin/nginx           /usr/sbin/nginx
COPY --from=build /usr/lib/nginx/modules/*  /usr/lib/nginx/modules/

ENV LUAJIT_LIB=/usr/local/lib \
    LUAJIT_INC=/usr/local/include/luajit

RUN set -x \
    && apt-get update \
    && apt-get install -y --no-install-suggests \
        # Required for ModSecurity
        libcurl4-openssl-dev liblmdb-dev \
    && ldconfig -v 2>&1 \
    && openssl version -a \
    && luajit -v \
    && nginx -V 2>&1 \
    && sed -i -E 's|listen\s+80|&80|g' /etc/nginx/conf.d/default.conf \
    && ln -sf /dev/stdout /var/log/modsec_audit.log \
    && touch /var/run/nginx.pid \
    && mkdir -p /var/cache/nginx \
    && chown -R nginx:nginx /etc/nginx /var/log/nginx /var/cache/nginx /var/run/nginx.pid /var/log/modsec_audit.log

USER nginx

WORKDIR /etc/nginx
