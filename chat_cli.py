import json
import os
import sys
import urllib.error
import urllib.request

API_URL = os.environ.get("RAG_API_URL")
API_KEY = os.environ.get("RAG_API_KEY")

if not API_URL or not API_KEY:
    print("Set RAG_API_URL and RAG_API_KEY environment variables first.")
    sys.exit(1)

session_id = None
print("Connected to Bedrock Knowledge Base. Type 'exit' to quit.\n")

while True:
    prompt = input("You: ").strip()
    if prompt.lower() in {"exit", "quit"}:
        break
    if not prompt:
        continue

    payload = {"prompt": prompt}
    if session_id:
        payload["session_id"] = session_id

    req = urllib.request.Request(
        API_URL,
        data=json.dumps(payload).encode("utf-8"),
        headers={"x-api-key": API_KEY, "Content-Type": "application/json"},
        method="POST",
    )

    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        print(f"HTTP Error {e.code}: {e.read().decode('utf-8')}")
        continue

    session_id = data.get("session_id", session_id)
    print(f"\nAssistant [{data.get('guardrail_action')}]: {data.get('answer')}")
    if data.get("sources"):
        print("Sources:", ", ".join(data["sources"]))
    print("-" * 60)
