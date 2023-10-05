# syntax=docker/dockerfile:1-labs
FROM public.ecr.aws/docker/library/alpine:3.18 AS base
ENV TZ=UTC

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

# apply available patches
RUN apk add --no-cache patch
COPY patches ./
RUN find ./ -name "*.patch" -print0 | sort -z | xargs -t -0 -n1 patch -p1 -i

# frontend stage ===============================================================
FROM base AS build-frontend
WORKDIR /src

# dependencies
RUN apk add --no-cache nodejs-current && corepack enable

# node_modules
COPY --from=source /src/package.json /src/yarn.lock /src/tsconfig.json ./
RUN yarn install --frozen-lockfile --network-timeout 120000

# frontend source and build
COPY --from=source /src/frontend ./frontend
RUN yarn build --env production --no-stats

# cleanup
RUN find ./ -name "*.map" -type f -delete && \
    mv ./_output/UI /build

# normalize arch ===============================================================
FROM base AS base-arm64
ENV RUNTIME=linux-musl-arm64
FROM base AS base-amd64
ENV RUNTIME=linux-musl-x64

# backend stage ================================================================
FROM base-$TARGETARCH AS build-backend
WORKDIR /src

# dependencies
RUN apk add --no-cache dotnet6-sdk

# dotnet source
COPY --from=source /src/.editorconfig ./
COPY --from=source /src/Logo ./Logo
COPY --from=source /src/src ./src

# sonarr versioning
RUN buildprops=./src/Directory.Build.props && \
    sed -i "/<AssemblyConfiguration>/s/>.*<\//>$BRANCH<\//" "$buildprops" && \
    sed -i "/<AssemblyVersion>/s/>.*<\//>$VERSION<\//" "$buildprops"
COPY <<EOF /build/package_info
PackageAuthor=[fabricionaweb](https://github.com/fabricionaweb/docker-sonarr)
UpdateMethod=Docker
Branch=$BRANCH
PackageVersion=$COMMIT
EOF

# build backend
RUN dotnet build ./src/Sonarr.sln \
        -p:RuntimeIdentifiers=$RUNTIME \
        -p:Configuration=Release \
        -p:SelfContained=false \
        -t:PublishAllRids

# cleanup
RUN find ./ \( \
        -name "ServiceUninstall.*" -o \
        -name "ServiceInstall.*" -o \
        -name "Sonarr.Windows.*" \
    \) | xargs rm -rf && \
    mv ./_output/net6.0/$RUNTIME/publish /build/bin && \
    chmod +x /build/bin/ffprobe

# runtime stage ================================================================
FROM base

ENV S6_VERBOSITY=0 S6_BEHAVIOUR_IF_STAGE2_FAILS=2 PUID=65534 PGID=65534
WORKDIR /config
VOLUME /config
EXPOSE 8989

# copy files
COPY --from=build-backend /build /app
COPY --from=build-frontend /build /app/bin/UI
COPY ./rootfs /

# runtime dependencies
RUN apk add --no-cache tzdata s6-overlay aspnetcore6-runtime sqlite-libs curl

# run using s6-overlay
ENTRYPOINT ["/init"]
