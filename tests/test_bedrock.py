import json
import os

import boto3
from dotenv import load_dotenv

load_dotenv()

target_lang = "en"
text = "こんにちは！"


client = boto3.client("bedrock-runtime", region_name=os.getenv("AWS_REGION"))

if target_lang == "en":
    prompt = f"Translate the following text to English. Only provide the translation, no explanations:\n\n{text}"
else:
    prompt = f"Translate the following text to Japanese. Only provide the translation, no explanations:\n\n{text}"

# Use Amazon Nova Pro for translation
body = {"messages": [{"role": "user", "content": [{"text": prompt}]}]}

response = client.invoke_model(
    modelId="apac.amazon.nova-pro-v1:0",
    body=json.dumps(body),
    contentType="application/json",
)

response_body = json.loads(response["body"].read())
translated_text = response_body["output"]["message"]["content"][0]["text"].strip()
print(translated_text)
