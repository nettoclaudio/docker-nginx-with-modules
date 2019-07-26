ARG nginx_version=1.16.0
FROM nginx:${nginx_version} AS build

SHELL ["/bin/bash", "-c"]

RUN set -x \
    && apt-get update \
    && apt-get install -y --no-install-suggests \
       libluajit-5.1-dev libpam0g-dev zlib1g-dev libpcre3-dev \
       libexpat1-dev git curl build-essential libxml2 libxslt1.1 libxslt1-dev autoconf libtool libssl-dev

ARG modsecurity_version=v3.0.3
RUN set -x \
    && git clone --depth 1 -b ${modsecurity_version} https://github.com/SpiderLabs/ModSecurity.git /usr/local/src/modsecurity \
    && cd /usr/local/src/modsecurity \
    && git submodule init \
    && git submodule update \
    && ./build.sh \
    && ./configure \
    && make \
    && make install

ARG owasp_modsecurity_crs_version=v3.1.0
RUN set -x \
    && nginx_modsecurity_conf_dir="/etc/nginx/conf.d/modsecurity" \
    && mkdir -p ${nginx_modsecurity_conf_dir} \
    && cd ${nginx_modsecurity_conf_dir} \
    && curl -fSL "https://github.com/SpiderLabs/owasp-modsecurity-crs/archive/${owasp_modsecurity_crs_version}.tar.gz" \
    |  tar -xvzf - \
    && mv owasp-modsecurity-crs{-${owasp_modsecurity_crs_version#v},} \
    && cd -

RUN set -x \
    && nginx_version=$(echo ${NGINX_VERSION} | sed 's/-.*//g') \
    && curl -fSL "https://nginx.org/download/nginx-${nginx_version}.tar.gz" \
    |  tar -C /usr/local/src -xzvf- \
    && ln -s /usr/local/src/nginx-${nginx_version} /usr/local/src/nginx

ARG modules
RUN set -x \
    && cd /usr/src/nginx \
    && configure_args=$(nginx -V 2>&1 | grep "configure arguments:" | awk -F 'configure arguments:' '{print $2}'); \
    IFS=','; \
    for module in ${modules}; do \
        module_repo=$(echo $module | sed -E 's@^(((https?|git)://)?[^:]+).*@\1@g'); \
        module_tag=$(echo $module | sed -E 's@^(((https?|git)://)?[^:]+):?([^:/]*)@\4@g'); \
        dirname=$(echo "${module_repo}" | sed -E 's@^.*/|\..*$@@g'); \
        git clone "${module_repo}"; \
        cd ${dirname}; \
        git fetch --tags; \
        if [ -n "${module_tag}" ]; then \
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
    done; unset IFS \
    && eval ./configure ${configure_args} \
    && make modules \
    && mkdir /modules \
    && cp $(pwd)/objs/*.so /modules

RUN strip /usr/local/modsecurity/bin/* /usr/local/modsecurity/lib/*.a /usr/local/modsecurity/lib/*.so*

FROM nginx:${nginx_version}

COPY --from=build /modules/* /usr/lib/nginx/modules/
COPY --from=build /usr/local/modsecurity/ /usr/local/modsecurity/
COPY --from=build /etc/nginx/conf.d/modsecurity /etc/nginx/conf.d/modsecurity

ENV DEBIAN_FRONTEND noninteractive

RUN apt update \
    && apt-get install -y \
      ca-certificates \
      curl \
      dnsutils \
      iputils-ping \
      libcurl4-openssl-dev \
      libyajl-dev \
      libluajit-5.1-2 \
      libxml2 \
      lua5.1-dev \
      luajit \
      net-tools \
      procps \
      tcpdump \
      vim-tiny \
    && apt clean \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /etc/nginx/modules/all.conf \
    && ls /etc/nginx/modules/*.so | grep -v debug \
      | xargs -I{} sh -c 'echo "load_module {};" | tee -a  /etc/nginx/modules/all.conf'

WORKDIR /etc/nginx
