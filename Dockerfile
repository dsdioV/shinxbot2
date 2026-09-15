FROM debian:12

ARG IMAGEMAGICK_VERSION=7.1.1-43

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    cmake \
    pkg-config \
    python3 \
    curl \
    xz-utils \
    ca-certificates \
    git \
    libcurl4-openssl-dev \
    openssl \
    libssl-dev \
    libjsoncpp-dev \
    libzip-dev \
    libjpeg-dev \
    libpng-dev \
    libtiff-dev \
    libgif-dev \
    libwebp-dev \
    webp \
    libxml2-dev \
    libltdl-dev \
    libfmt-dev \
    libfreetype-dev \
    libfontconfig1-dev \
    fontconfig \
    fonts-dejavu-core && \
    rm -rf /var/lib/apt/lists/*

# Build ImageMagick 7 because Debian 12 apt provides ImageMagick 6 by default.
# The source comes from the GitHub tag tarball: imagemagick.org/archive/releases
# now returns 404, and the GitHub release for this version ships no source asset.
# libfreetype is required for text rendering; without it annotate() cannot draw.
RUN set -eux; \
    cd /tmp; \
    curl -fsSL -o "ImageMagick-${IMAGEMAGICK_VERSION}.tar.gz" "https://github.com/ImageMagick/ImageMagick/archive/refs/tags/${IMAGEMAGICK_VERSION}.tar.gz"; \
    tar -xzf "ImageMagick-${IMAGEMAGICK_VERSION}.tar.gz"; \
    cd "ImageMagick-${IMAGEMAGICK_VERSION}"; \
    ./configure \
        --prefix=/usr/local \
        --with-modules \
        --with-magick-plus-plus=yes \
        --disable-static; \
    make -j"$(nproc)"; \
    make install; \
    ldconfig; \
    magick -version; \
    rm -rf /tmp/ImageMagick-* /tmp/*.tar.gz
