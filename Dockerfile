# kraken — always-on dev box on Railway.
# This image is the disposable layer. Everything that must persist lives in
# /home/nfp, a mounted Railway volume (repos, dotfiles, node via fnm, logins).

FROM debian:trixie-slim
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl wget gnupg \
      git openssh-client tmux ripgrep less vim procps sudo locales unzip \
      build-essential pkg-config python3 python3-venv \
      chromium fonts-liberation fonts-noto-color-emoji \
    && rm -rf /var/lib/apt/lists/*
# `chromium` is only here to pull in every shared library Playwright's own
# Chromium build needs; `npx playwright install chromium` then just works.

# GitHub CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# Tailscale (userspace-networking mode; Railway containers have no /dev/net/tun)
RUN curl -fsSL https://pkgs.tailscale.com/stable/debian/trixie.noarmor.gpg \
      -o /usr/share/keyrings/tailscale-archive-keyring.gpg \
    && curl -fsSL https://pkgs.tailscale.com/stable/debian/trixie.tailscale-keyring.list \
      -o /etc/apt/sources.list.d/tailscale.list \
    && apt-get update && apt-get install -y --no-install-recommends tailscale \
    && rm -rf /var/lib/apt/lists/*

# uv system-wide. Node is NOT in the image: install fnm into $HOME once (on the volume).
RUN curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh

RUN sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8

# Non-root user; home is the volume mount point (entrypoint fixes ownership on boot).
RUN useradd -m -u 1000 -s /bin/bash nfp \
    && echo "nfp ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/nfp

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENV HOME=/home/nfp
ENV PATH=/home/nfp/.local/bin:/home/nfp/.local/share/fnm:${PATH}
WORKDIR /home/nfp

# Runs as root: chown volume, start tailscaled, then park. Shells are nfp.
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
