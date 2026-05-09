# Override the upstream cognee-mcp image, with two compounded reductions:
#
# (1) Remove `triton` (~639MB). Triton is the GPU kernel compiler — only
#     used when torch.compile() targets CUDA. CT 105 has no GPU.
#
# (2) Drive the actual size reduction via build.sh's `docker export |
#     docker import` flatten step, which collapses the upstream's
#     chown-after-COPY anti-pattern (an extra ~6GB whiteout layer
#     duplicating /app/.venv) into a single layer.
#
# Why we don't uninstall nvidia-*-cu12: torch 2.7+ slim-wheels are
# dynamically linked to libcudart/libcublasLt and `_preload_cuda_deps` in
# torch/__init__.py errors out at import time if the nvidia-*-cu12 wheels
# are absent — even on CPU-only hosts. Keeping them as inert library
# files is the only path that lets `import torch` succeed.
FROM cognee/cognee-mcp:latest

USER root
RUN /app/.venv/bin/uv pip uninstall --python /app/.venv/bin/python triton \
 && python3 -c "import torch; print('torch', torch.__version__, 'cuda_available', torch.cuda.is_available())"
USER cognee
