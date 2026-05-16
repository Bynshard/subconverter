ARG ALPINE_VERSION=3.22

FROM alpine:${ALPINE_VERSION} AS builder

ARG THREADS=2
ARG QUICKJSPP_COMMIT=0c00c48895919fc02da3f191a2da06addeb07f09
ARG CURL_BRANCH=curl-8_6_0
ARG TOML11_VERSION=v4.3.0
ARG INCLUDE_RULES=1

RUN apk add --no-cache \
        build-base \
        ca-certificates \
        cmake \
        git \
        linux-headers \
        mbedtls-dev \
        mbedtls-static \
        pcre2-dev \
        pcre2-static \
        pkgconf \
        python3 \
        rapidjson-dev \
        zlib-dev \
        zlib-static

WORKDIR /tmp/deps

RUN git clone --depth=1 --branch "${CURL_BRANCH}" https://github.com/curl/curl.git curl && \
    cmake -S curl -B curl/build \
        -DCMAKE_BUILD_TYPE=MinSizeRel \
        -DCMAKE_INSTALL_PREFIX=/usr \
        -DBUILD_CURL_EXE=OFF \
        -DBUILD_SHARED_LIBS=OFF \
        -DBUILD_TESTING=OFF \
        -DCMAKE_USE_LIBSSH2=OFF \
        -DCURL_BROTLI=OFF \
        -DCURL_DISABLE_LDAP=ON \
        -DCURL_DISABLE_LDAPS=ON \
        -DCURL_USE_LIBPSL=OFF \
        -DCURL_USE_MBEDTLS=ON \
        -DCURL_ZSTD=OFF \
        -DHTTP_ONLY=ON \
        -DUSE_NGHTTP2=OFF && \
    cmake --build curl/build --target install -j "${THREADS}"

RUN git clone --depth=1 https://github.com/jbeder/yaml-cpp.git yaml-cpp && \
    cmake -S yaml-cpp -B yaml-cpp/build \
        -DCMAKE_BUILD_TYPE=MinSizeRel \
        -DCMAKE_INSTALL_PREFIX=/usr \
        -DYAML_BUILD_SHARED_LIBS=OFF \
        -DYAML_CPP_BUILD_CONTRIB=OFF \
        -DYAML_CPP_BUILD_TESTS=OFF \
        -DYAML_CPP_BUILD_TOOLS=OFF && \
    cmake --build yaml-cpp/build --target install -j "${THREADS}"

RUN git clone --no-checkout https://github.com/ftk/quickjspp.git quickjspp && \
    cd quickjspp && \
    git fetch --depth=1 origin "${QUICKJSPP_COMMIT}" && \
    git checkout "${QUICKJSPP_COMMIT}" && \
    git submodule update --init --depth=1 && \
    cmake -S . -B build -DCMAKE_BUILD_TYPE=MinSizeRel && \
    cmake --build build --target quickjs -j "${THREADS}" && \
    install -d /usr/lib/quickjs /usr/include/quickjs && \
    install -m644 build/quickjs/libquickjs.a /usr/lib/quickjs/ && \
    install -m644 quickjs/quickjs.h quickjs/quickjs-libc.h /usr/include/quickjs/ && \
    install -m644 quickjspp.hpp /usr/include/

RUN git clone --depth=1 https://github.com/PerMalmberg/libcron.git libcron && \
    cd libcron && \
    git submodule update --init --depth=1 && \
    cmake -S . -B build \
        -DCMAKE_BUILD_TYPE=MinSizeRel \
        -DCMAKE_INSTALL_PREFIX=/usr \
        -DBUILD_SHARED_LIBS=OFF && \
    cmake --build build --target libcron install -j "${THREADS}"

RUN git clone --depth=1 --branch "${TOML11_VERSION}" https://github.com/ToruNiina/toml11.git toml11 && \
    cmake -S toml11 -B toml11/build \
        -DCMAKE_BUILD_TYPE=MinSizeRel \
        -DCMAKE_CXX_STANDARD=11 \
        -DCMAKE_INSTALL_PREFIX=/usr && \
    cmake --build toml11/build --target install -j "${THREADS}"

WORKDIR /src/subconverter
COPY . .

RUN cmake -S . -B build \
        -DCMAKE_BUILD_TYPE=MinSizeRel \
        -DCMAKE_CXX_FLAGS="-Os -ffunction-sections -fdata-sections" && \
    cmake --build build -j "${THREADS}" && \
    g++ -static -Os -s -Wl,--gc-sections \
        -o /tmp/subconverter-static \
        $(find build/CMakeFiles/subconverter.dir/src -name "*.o" | sort) \
        -lcurl \
        -lyaml-cpp \
        -lpcre2-8 \
        /usr/lib/quickjs/libquickjs.a \
        -llibcron \
        -lmbedtls \
        -lmbedx509 \
        -lmbedcrypto \
        -lz \
        -pthread \
        -latomic && \
    mkdir -p /out/base && \
    cp -a base/. /out/base/ && \
    install -m755 /tmp/subconverter-static /out/base/subconverter && \
    if [ "${INCLUDE_RULES}" != "1" ]; then rm -rf /out/base/rules; fi && \
    find /out/base -name ".git*" -exec rm -rf {} +

FROM scratch

COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=builder /out/base /base

ENV TZ=UTC
WORKDIR /base
EXPOSE 25500/tcp
ENTRYPOINT ["/base/subconverter"]
