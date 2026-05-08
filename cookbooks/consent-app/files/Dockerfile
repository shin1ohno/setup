FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

EXPOSE 9020

# Drop privileges before running the OAuth-facing FastAPI app.
USER nobody:nogroup

CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "9020"]
