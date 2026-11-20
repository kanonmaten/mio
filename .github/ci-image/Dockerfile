# Container for "Verifiera Mio på Linux" (.github/workflows/verify-linux.yml), built and pushed
# to ghcr.io/kanonmaten/mio/verify-linux by .github/workflows/ci-image.yml. It holds what the job
# used to install on every run, so the verify job starts straight at checkout.
#
# The verifier's structure check (tools/src/project.rs) requires this exact base image: the
# Swift toolchain here is the one the portable Swift tests run on.
FROM swift:6.3.3-noble

# The Swift image has no python3 or curl; uv and the Pianissimo tests use the system
# interpreter, rustup needs curl, and the gateway's TLS library compiles C code with gcc.
# The rest is what gpui-kit lists for Ubuntu 24.04, for the control panel in control/.
RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 ca-certificates curl gcc libc6-dev \
      g++ cmake pkg-config libfontconfig-dev libwayland-dev libxkbcommon-x11-dev libx11-xcb-dev \
      libssl-dev libzstd-dev libvulkan1 \
 && rm -rf /var/lib/apt/lists/*

# Rust lives outside HOME: GitHub container jobs run as root with HOME=/github/home, a volume
# mounted over the image, so anything installed under the build-time HOME would not be found.
ENV RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    PATH=/usr/local/cargo/bin:$PATH

# Rust 1.100.0 is also pinned in the Mac concurrency step of
# .github/workflows/build-unsigned-ipa.yml, and tools/src/gate.rs refuses toolchains below its
# minimum versions (1.88 for the verifier, 1.92 for control/). Move them together.
# Downloaded to a file first: a failed download must fail the build, not pipe nothing into sh.
# rustup checks the toolchain download itself.
RUN set -eu \
 && curl --proto '=https' --tlsv1.2 -sSf -o /tmp/rustup-init.sh https://sh.rustup.rs \
 && sh /tmp/rustup-init.sh -y --no-modify-path --profile minimal --component clippy --default-toolchain 1.100.0 \
 && rm /tmp/rustup-init.sh \
 && cargo --version \
 && cargo clippy --version

# uv 0.12.22 from Astral's image, pinned by the digest of that tag's multi-arch index.
COPY --from=ghcr.io/astral-sh/uv:0.12.22@sha256:f513a91fc62fe7c17567eee97230dd198e43edb8a9fbecca843714a4358fe1bc /uv /uvx /usr/local/bin/
