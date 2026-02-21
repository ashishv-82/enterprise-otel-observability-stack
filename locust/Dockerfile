FROM python:3.11-slim

WORKDIR /mnt/locust

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY locustfile.py .

# Run locust in headless mode, automatically targeting the FastAPI app
# Spawns up to 10 users, adding 1 user per second
CMD ["locust", "-f", "locustfile.py", "--headless", "-u", "10", "-r", "1", "--host", "http://app:8000"]
