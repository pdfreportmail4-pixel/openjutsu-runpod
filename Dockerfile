# syntax=docker/dockerfile:1.7
# OpenJutsu + ComfyUI + MiniMax H3 image for RunPod.
# Software is baked in; models (~51 GB) are downloaded to the container disk at every start.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    NEXT_TELEMETRY_DISABLED=1 \
    SAM2_BUILD_CUDA=0 \
    COMFYUI_PATH=/opt/ComfyUI \
    PATH=/opt/venv/bin:$PATH

# 1) System packages + Node.js 22 (OpenJutsu needs Node 22.6+)
RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 python3-venv python3-dev build-essential git curl ca-certificates procps \
        ffmpeg libgl1 libglib2.0-0 openssh-server rsync tini \
    && curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# 2) Python env + PyTorch built for CUDA 13.0 (needed for the fast int8_convrot path)
ARG TORCH_INDEX=https://download.pytorch.org/whl/cu130
RUN python3 -m venv /opt/venv \
    && pip install --upgrade pip setuptools wheel \
    && pip install torch torchvision --index-url ${TORCH_INDEX} \
    && pip install torchaudio \
    && python -c "import torch; v = torch.version.cuda or ''; assert v.startswith('13'), f'torch is not a CUDA 13 build: {v}'; print('torch', torch.__version__, 'CUDA', v)" \
    && pip freeze | grep -iE '^(torch|torchvision|torchaudio)==' > /opt/constraints.txt \
    && cat /opt/constraints.txt

# 3) ComfyUI, pinned (OpenJutsu needs 0.41.2+)
ARG COMFYUI_REF=v0.45.1
RUN git clone --filter=blob:none --quiet https://github.com/Comfy-Org/ComfyUI.git /opt/ComfyUI \
    && git -C /opt/ComfyUI checkout --quiet ${COMFYUI_REF} \
    && pip install -c /opt/constraints.txt -r /opt/ComfyUI/requirements.txt

# 4) Custom nodes, pinned commits, plus an import test that fails the build if a required pack breaks
COPY scripts/install_nodes.sh /opt/scripts/install_nodes.sh
RUN sed -i 's/\r$//' /opt/scripts/install_nodes.sh && bash /opt/scripts/install_nodes.sh

# 5) comfy-api-proxy (own venv, patched like start_openjutsu.bat does) + OpenJutsu app
ARG OPENJUTSU_REF=7fe118bb5a61fcfac0148e1bfea3dd29884dbf26
COPY scripts/patch_openjutsu.py /opt/scripts/patch_openjutsu.py
RUN git clone --filter=blob:none --quiet https://github.com/D3voz/openjutsu.git /opt/openjutsu \
    && git -C /opt/openjutsu checkout --quiet ${OPENJUTSU_REF} \
    && python3 -m venv /opt/proxy-venv \
    && /opt/proxy-venv/bin/pip install comfy-api-proxy==0.1.6 \
    && /opt/proxy-venv/bin/python /opt/openjutsu/patch_proxy.py \
    && python /opt/scripts/patch_openjutsu.py \
    && (git -C /opt/ComfyUI/custom_nodes/SolarRenderer apply /opt/openjutsu/patches/solarrenderer-long-clips.patch \
        && echo "SolarRenderer long-clip patch applied" || echo "SolarRenderer patch skipped") \
    && cd /opt/openjutsu && cp .env.example .env.local && npm ci && npm run build

# 6) Runtime scripts
COPY scripts/start.sh scripts/download_models.sh scripts/models_bg.sh scripts/ssh_setup.sh /opt/scripts/
RUN sed -i 's/\r$//' /opt/scripts/*.sh && chmod +x /opt/scripts/*.sh \
    && printf 'ComfyUI %s\nOpenJutsu %s\n' "${COMFYUI_REF}" "${OPENJUTSU_REF}" > /opt/versions.txt \
    && cat /opt/constraints.txt >> /opt/versions.txt

EXPOSE 22
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/opt/scripts/start.sh"]
