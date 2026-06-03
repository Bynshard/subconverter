ARG ALPINE_VERSION=3.16

FROM alpine:${ALPINE_VERSION} AS builder

ARG THREADS=4
ARG QUICKJSPP_COMMIT=0c00c48895919fc02da3f191a2da06addeb07f09
ARG TOML11_VERSION=v4.3.0
ARG INCLUDE_RULES=1

WORKDIR /

RUN apk add --no-cache --virtual .build-tools \
        build-base \
        cmake \
        g++ \
        git \
        linux-headers \
        python3 && \
    apk add --no-cache --virtual .build-deps \
        curl-dev \
        pcre2-dev \
        rapidjson-dev \
        yaml-cpp-dev

RUN git clone --no-checkout https://github.com/ftk/quickjspp.git quickjspp && \
    cd quickjspp && \
    git fetch --depth=1 origin "${QUICKJSPP_COMMIT}" && \
    git checkout "${QUICKJSPP_COMMIT}" && \
    git submodule update --init --depth=1 && \
    cmake -S . -B build -DCMAKE_BUILD_TYPE=Release && \
    cmake --build build --target quickjs -j "${THREADS}" && \
    install -d /usr/lib/quickjs /usr/include/quickjs && \
    install -m644 build/quickjs/libquickjs.a /usr/lib/quickjs/ && \
    install -m644 quickjs/quickjs.h quickjs/quickjs-libc.h /usr/include/quickjs/ && \
    install -m644 quickjspp.hpp /usr/include/

RUN git clone --depth=1 https://github.com/PerMalmberg/libcron.git libcron && \
    cd libcron && \
    git submodule update --init --depth=1 && \
    cmake -S . -B build \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr \
        -DBUILD_SHARED_LIBS=OFF && \
    cmake --build build --target libcron install -j "${THREADS}"

RUN git clone --depth=1 --branch "${TOML11_VERSION}" https://github.com/ToruNiina/toml11.git toml11 && \
    cmake -S toml11 -B toml11/build \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_CXX_STANDARD=11 \
        -DCMAKE_INSTALL_PREFIX=/usr && \
    cmake --build toml11/build --target install -j "${THREADS}"

WORKDIR /src/subconverter
COPY . .

RUN cmake -S . -B build -DCMAKE_BUILD_TYPE=Release && \
    cmake --build build -j "${THREADS}" && \
    mkdir -p /out/base && \
    cp -a base/. /out/base/ && \
    install -m755 build/subconverter /out/subconverter && \
    if [ "${INCLUDE_RULES}" != "1" ]; then rm -rf /out/base/rules; fi && \
    find /out/base -name ".git*" -exec rm -rf {} +

FROM alpine:${ALPINE_VERSION}

RUN apk add --no-cache --virtual subconverter-deps \
        libcurl \
        pcre2 \
        yaml-cpp

COPY --from=builder /out/subconverter /usr/bin/subconverter
COPY --from=builder /out/base /base

ENV TZ=Africa/Abidjan
RUN ln -sf /usr/share/zoneinfo/$TZ /etc/localtime && \
    echo $TZ > /etc/timezone

WORKDIR /base
EXPOSE 25500/tcp
CMD ["subconverter"]
