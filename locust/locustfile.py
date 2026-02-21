import random
import time
from locust import HttpUser, task, between

class FastApiUser(HttpUser):
    # Wait between 1 and 3 seconds between tasks
    wait_time = between(1, 3)

    @task(5)
    def get_items(self):
        # 5x more likely to hit the happy path
        self.client.get("/items/1")
        self.client.get("/items/2")

    @task(2)
    def get_health(self):
        # 2x likelihood of checking health
        self.client.get("/health")

    @task(1)
    def cause_crash(self):
        # 1x likelihood of triggering an explicit 500 error
        # We catch the exception in Locust so the load test doesn't fail,
        # but the backend will still record the 500 in OTel logs/traces.
        with self.client.get("/crash", catch_response=True) as response:
            if response.status_code == 500:
                response.success()
            else:
                response.failure(f"Expected 500, got {response.status_code}")
