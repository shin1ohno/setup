FROM python:3.12-slim
WORKDIR /app
RUN pip install --no-cache-dir watchfiles==0.24.0 httpx==0.27.2
COPY watch.py .
CMD ["python", "-u", "watch.py"]
