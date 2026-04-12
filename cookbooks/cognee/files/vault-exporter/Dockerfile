FROM python:3.12-slim
WORKDIR /app
RUN pip install --no-cache-dir httpx==0.27.2
ENV PYTHONUNBUFFERED=1
CMD ["python", "-u", "/scripts/watch_and_export.py"]
