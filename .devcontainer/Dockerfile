FROM mcr.microsoft.com/devcontainers/base:ubuntu

# Install build dependencies for Python, shellcheck, shfmt, curl, git, unzip
RUN apt-get update && export DEBIAN_FRONTEND=noninteractive \
    && apt-get -y install --no-install-recommends \
       shellcheck \
       shfmt \
       curl \
       ca-certificates \
       git \
       unzip \
       build-essential \
       libssl-dev \
       zlib1g-dev \
       libbz2-dev \
       libreadline-dev \
       libsqlite3-dev \
       libncursesw5-dev \
       xz-utils \
       tk-dev \
       libxml2-dev \
       libxmlsec1-dev \
       libffi-dev \
       liblzma-dev \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Install Lefthook
RUN curl -1sLf 'https://dl.cloudsmith.io/public/evilmartians/lefthook/setup.deb.sh' | bash \
    && apt-get update && apt-get install -y lefthook \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Install pyenv and Python for the vscode user
USER vscode
COPY --chown=vscode:vscode dependencies/ /tmp/dependencies/

ENV PYENV_ROOT="/home/vscode/.pyenv"
ENV FNM_PATH="/home/vscode/.local/share/fnm"
ENV PATH="${PYENV_ROOT}/shims:${PYENV_ROOT}/bin:${FNM_PATH}:/tmp/dependencies/node_modules/.bin:${PATH}"

RUN curl https://pyenv.run | bash \
    && echo 'export PYENV_ROOT="$HOME/.pyenv"' >> ~/.bashrc \
    && echo '[[ -d $PYENV_ROOT/bin ]] && export PATH="$PYENV_ROOT/bin:$PATH"' >> ~/.bashrc \
    && echo 'eval "$(pyenv init -)"' >> ~/.bashrc \
    && echo 'export PYENV_ROOT="$HOME/.pyenv"' >> ~/.zshrc \
    && echo '[[ -d $PYENV_ROOT/bin ]] && export PATH="$PYENV_ROOT/bin:$PATH"' >> ~/.zshrc \
    && echo 'eval "$(pyenv init -)"' >> ~/.zshrc

# Pre-install Python 3.11.9 and install dependencies
RUN pyenv install 3.11.9 && pyenv global 3.11.9 \
    && pip install --no-cache-dir -r /tmp/dependencies/requirements.txt

# Install fnm and Node.js v20 (LTS), then install Node dependencies
RUN curl -fsSL https://fnm.vercel.app/install | bash -s -- --install-dir "${FNM_PATH}" --skip-shell \
    && echo 'export PATH="/home/vscode/.local/share/fnm:$PATH"' >> ~/.bashrc \
    && echo 'eval "`fnm env`"' >> ~/.bashrc \
    && echo 'export PATH="/home/vscode/.local/share/fnm:$PATH"' >> ~/.zshrc \
    && echo 'eval "`fnm env`"' >> ~/.zshrc \
    && eval "$(fnm env)" && fnm install 20 && fnm default 20 \
    && cd /tmp/dependencies && npm install --no-audit --no-fund
