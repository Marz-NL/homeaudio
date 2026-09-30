FROM python:3.11-slim

WORKDIR /app
RUN pip install --no-cache-dir aiohttp

COPY guard.py ./
COPY static/ ./static/

EXPOSE 8091
CMD ["python3", "guard.py"]
