FROM mcr.microsoft.com/devcontainers/base:ubuntu AS devcontainer

# Install tools and dependencies via script
USER vscode
ENV HOME="/home/vscode"
COPY --chown=vscode:vscode .devcontainer/dependencies/ /tmp/dependencies/
COPY --chown=vscode:vscode .devcontainer/install-tools.sh /tmp/install-tools.sh

RUN env DEPS_DIR="/tmp/dependencies" bash /tmp/install-tools.sh --sys-deps

# Set environment variables for the installed tools
ENV PATH="${HOME}/.local/bin:${PATH}"
ENV PYENV_ROOT="${HOME}/.pyenv"
ENV PATH="${PYENV_ROOT}/shims:${PYENV_ROOT}/bin:${PATH}"
ENV FNM_PATH="${HOME}/.local/share/fnm"
ENV PATH="${FNM_PATH}/aliases/default/bin:${PATH}"
ENV PATH="${FNM_PATH}:/tmp/dependencies/node_modules/.bin:${PATH}"
ENV PATH="${HOME}/google-cloud-sdk/bin:${PATH}"

