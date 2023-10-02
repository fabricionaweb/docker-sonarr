# syntax=docker/dockerfile:1-labs
FROM public.ecr.aws/docker/library/alpine:3.18 AS base

# source stage =================================================================
FROM base AS source

WORKDIR /src
ARG BRANCH
ARG VERSION
ARG COMMIT=$VERSION

# mandatory build-arg
RUN test -n "$BRANCH" && test -n "$VERSION"

# get and extract source from git
ADD https://github.com/Sonarr/Sonarr.git#$BRANCH ./

# dependencies
RUN apk add --no-cache patch

# apply available patches
COPY patches ./
RUN find . -name "*.patch" -print0 | sort -z | xargs -t -0 -n1 patch -p1 -i

# frontend stage ===============================================================
FROM source AS build-frontend

# dependencies
RUN apk add --no-cache nodejs-current && \
    corepack enable

# build
RUN yarn install --frozen-lockfile --network-timeout 120000 && \
    yarn build --env production --no-stats

# normalize arch ===============================================================
FROM source AS build-arm64
ENV RUNTIME=linux-musl-arm64
FROM source AS build-amd64
ENV RUNTIME=linux-musl-x64

# backend stage ================================================================
FROM build-$TARGETARCH AS build-backend

# dependencies
RUN apk add --no-cache dotnet6-sdk

# patch VERSION
RUN buildprops=./src/Directory.Build.props && \
    sed -i -e "s/<AssemblyConfiguration>[\$()A-Za-z-]\+<\/AssemblyConfiguration>/<AssemblyConfiguration>$BRANCH<\/AssemblyConfiguration>/g" $buildprops && \
    sed -i -e "s/<AssemblyVersion>[0-9.*]\+<\/AssemblyVersion>/<AssemblyVersion>$VERSION<\/AssemblyVersion>/g" $buildprops
COPY <<EOF /build/package_info
PackageAuthor=[fabricionaweb](https://github.com/fabricionaweb/docker-sonarr)
UpdateMethod=Docker
Branch=$BRANCH
PackageVersion=$COMMIT
EOF

# build
ENV artifacts="/src/_output/net6.0/$RUNTIME/publish"
RUN dotnet build ./src \
        -p:RuntimeIdentifiers=$RUNTIME \
        -p:Configuration=Release \
        -p:SelfContained=false \
        -t:PublishAllRids && \
    chmod +x $artifacts/ffprobe

# merge frontend
COPY --from=build-frontend /src/_output/UI $artifacts/UI

# cleanup
RUN find ./ \( \
        -name "ServiceUninstall.*" -o \
        -name "ServiceInstall.*" -o \
        -name "Sonarr.Windows.*" -o \
        -name "*.map" \
    \) -delete && \
    mv $artifacts /build/bin

# runtime stage ================================================================
FROM base

ENV S6_VERBOSITY=0 S6_BEHAVIOUR_IF_STAGE2_FAILS=2 PUID=65534 PGID=65534
WORKDIR /config
VOLUME /config
EXPOSE 8989

# copy files
COPY --from=build-backend /build /app
COPY ./rootfs /

# runtime dependencies
RUN apk add --no-cache tzdata s6-overlay aspnetcore6-runtime sqlite-libs curl

# run using s6-overlay
ENTRYPOINT ["/init"]
