# NebulaOS unified build environment (Migration A).
#
# Replaces two previously-nested container dependencies with one:
#   - pellcorp/k1-bash-build (the outer Buildroot/kernel/rootfs environment)
#   - ghcr.io/coreflake1/guppydev (the GuppyScreen cross-compile toolchain)
#
# ...and replaces this file's own PREVIOUS role too: this used to be a thin
# orchestrator that talked to the host's Docker socket to launch those two
# nested images (see docs/HISTORY.md/git history for that design). This
# image now runs the numbered build stages directly - no nested Docker
# socket, no `docker run` from inside the container.
#
# What this image is: a host-level Linux environment with every build tool
# NebulaOS-firmware's scripts/build/00-06 pipeline actually invokes, baked in
# at image-build time instead of `apt-get install`'d mid-firmware-build.
#
# What this image is NOT: a place that contains project source, or a place
# that bundles a target MIPS compiler for the kernel/rootfs/native-app build.
# That compiler is Buildroot's own self-bootstrapped
# mipsel-buildroot-linux-gnu-* toolchain, built from source during Stage 03
# from this project's own pinned Buildroot revision (manifests/
# dependencies.conf's BUILDROOT_PIN) - this image supplies the HOST tools
# (gcc, make, python3, ...) Buildroot's own build process needs to bootstrap
# that target toolchain itself, not the target toolchain directly.
#
# The one target toolchain this image DOES bundle directly is GuppyScreen's
# Bootlin mips32el-musl cross-compiler (see "Migration A" section below) -
# Migration A's whole point is preserving that exact toolchain unchanged,
# not converging it onto Buildroot's target toolchain (that's Migration B,
# a separate, not-yet-executed experiment - see
# docs/NEBULAOS_BUILD_ENVIRONMENT.md).
#
# Audited (Phase 11, Task 2): pellcorp/k1-bash-build ALSO bundled an Ingenic
# mips-gcc720-glibc229 toolchain at /opt/toolchains/ - confirmed unused by
# any current build script (every kernel/rootfs/native-app compile already
# goes through Buildroot's own toolchain or GuppyScreen's Bootlin one). Not
# reproduced here - it was never load-bearing.

FROM ubuntu@sha256:3b06811b2afd352be909dd088a004166d665dc76d38b13eada33522a9d915c6f
# = docker.io/library/ubuntu:22.04 at the time this was pinned (2026-08-15).
# See versions.env for why 22.04 (matches the already-audited guppydev base).

ARG DEBIAN_FRONTEND=noninteractive

# --- Host build tools -------------------------------------------------------
# Exact superset actually required by scripts/build/*.sh - derived from (1)
# what pellcorp/k1-bash-build already had baked in (make, cmake, perl, git,
# wget, tar, xz-utils, bzip2, gzip, patch, diffutils, e2fsprogs,
# qemu-user-static) and (2) every `apt-get install` this project's own stage
# scripts currently run at build time (grepped from scripts/build/00-06 -
# not guessed), listed here so the real build never needs network access to
# an apt mirror mid-build again:
#   02/05:    python3 bc cpio rsync unzip bison flex libncurses5-dev file
#             build-essential libssl-dev libelf-dev
#   03:       (all of the above, plus, for Python's own Buildroot build)
#             libffi-dev zlib1g-dev libsqlite3-dev libexpat1-dev libbz2-dev
#             liblzma-dev libreadline-dev libgdbm-dev uuid-dev pkg-config
#             autoconf automake libtool gettext texinfo help2man libjpeg-dev
#             libpng-dev libtiff-dev libwebp-dev libopenjp2-7-dev
#   04:       python3-pip autoconf automake libtool gettext autopoint pkg-config
#   06:       e2fsprogs git (already covered above)
# Plus this file's own previous requirements (git, curl, ca-certificates,
# tar, gzip, unzip, coreutils, openssh-client) and device-tree-compiler/
# squashfs-tools for completeness (Buildroot bootstraps its own host-
# variants of some of these from source regardless, but the outer
# pipeline's own non-Buildroot steps - chelper/ustreamer/v4l2-ctl
# cross-compiles - use the system copies directly). Deliberately NOT
# included: docker.io (no nested Docker in this design any more).
RUN apt-get update && apt-get install -y --no-install-recommends \
		build-essential \
		cmake \
		make \
		perl \
		git \
		ca-certificates \
		wget \
		curl \
		tar \
		xz-utils \
		bzip2 \
		gzip \
		unzip \
		patch \
		diffutils \
		file \
		bc \
		cpio \
		rsync \
		bison \
		flex \
		libncurses5-dev \
		libssl-dev \
		libelf-dev \
		libffi-dev \
		zlib1g-dev \
		libsqlite3-dev \
		libexpat1-dev \
		libbz2-dev \
		liblzma-dev \
		libreadline-dev \
		libgdbm-dev \
		uuid-dev \
		texinfo \
		help2man \
		libjpeg-dev \
		libpng-dev \
		libtiff-dev \
		libwebp-dev \
		libopenjp2-7-dev \
		python3 \
		python3-pip \
		autoconf \
		automake \
		libtool \
		gettext \
		pkg-config \
		e2fsprogs \
		device-tree-compiler \
		squashfs-tools \
		qemu-user-static \
		openssh-client \
		coreutils \
	&& rm -rf /var/lib/apt/lists/*

# --- Migration A: GuppyScreen's exact current toolchain, preserved --------
# Identical pin to NebulaOS-guppyscreen/docker/Dockerfile's own ARGs (see
# build-env/versions.env - single source of truth for these values, kept in
# sync with that Dockerfile by inspection, not by import, since they live in
# different repos). Migration A's proof is that ONLY container ownership
# changes here - the compiler, libc, and linkage model GuppyScreen actually
# gets stay byte-for-byte the same.
ARG GUPPYSCREEN_MIPS_TOOLCHAIN=mips32el--musl--stable-2024.02-1
ARG GUPPYSCREEN_MIPS_URL=https://toolchains.bootlin.com/downloads/releases/toolchains/mips32el/tarballs/mips32el--musl--stable-2024.02-1.tar.bz2
ARG GUPPYSCREEN_MIPS_SHA256=25c0b3217df1bf1a7bae2cc4f56cdeab9fec98b172bbf0b336b2e8fe41d3ee4e

WORKDIR /toolchains
RUN wget -q "$GUPPYSCREEN_MIPS_URL" -O mips.tar.bz2 \
	&& echo "${GUPPYSCREEN_MIPS_SHA256}  mips.tar.bz2" | sha256sum -c - \
	&& tar xjf mips.tar.bz2 \
	&& rm mips.tar.bz2

# Deliberately NOT put on the image's default PATH (unlike the old
# ghcr.io/coreflake1/guppydev image, where it safely could be - that
# container never ran anything else). Found live while testing this image
# with build-env/verify-environment.sh: the Bootlin toolchain ships its own
# bundled `autoreconf`/`automake`/`aclocal` (for building target-side
# autotools packages within its own SDK) at
# /toolchains/.../bin/autoreconf, and that copy is BROKEN in this container
# ("Can't locate Autom4te/ChannelDefs.pm") - exactly the same class of
# shadowing bug scripts/build/04-cross-compile-app-stack.sh's ustreamer/
# v4l2-ctl sections already document and guard against for Buildroot's own
# host/bin (see those sections' own "append, not prepend" comments) - this
# is the identical failure mode from the OTHER toolchain this image also
# bundles. v4l2-ctl's `autoreconf -fiv` step would silently break if this
# were on PATH globally. Instead, scripts/build/04-cross-compile-app-stack.sh's
# own GuppyScreen section adds it to PATH itself, scoped to just that step.
ENV GUPPYSCREEN_TOOLCHAIN_BIN=/toolchains/${GUPPYSCREEN_MIPS_TOOLCHAIN}/bin

WORKDIR /work

LABEL org.opencontainers.image.source="https://github.com/NebulaOS-KE/NebulaOS-firmware" \
      org.opencontainers.image.title="NebulaOS Build Environment" \
      org.opencontainers.image.description="Canonical unified build environment for NebulaOS - replaces pellcorp/k1-bash-build and ghcr.io/coreflake1/guppydev with one NebulaOS-owned, digest-pinned image. Does not contain project source or the Buildroot-generated target toolchain (that's built from source at build time, per manifests/dependencies.conf)."

ENTRYPOINT ["sh", "-c"]
