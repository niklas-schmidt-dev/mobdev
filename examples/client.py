"""Minimal standard-library client. Set MOBDEV_TOKEN from your local token file."""
import json
import os
from urllib.request import Request, urlopen


def call(route, data=None):
    request = Request(
        os.environ.get("MOBDEV_URL", "http://127.0.0.1:4686") + "/api/v1" + route,
        data=None if data is None else json.dumps(data).encode(),
        headers={"Authorization": "Bearer " + os.environ["MOBDEV_TOKEN"], "Content-Type": "application/json"},
    )
    with urlopen(request, timeout=30) as response:
        return json.load(response)


if __name__ == "__main__":
    print(json.dumps(call("/devices"), indent=2))
