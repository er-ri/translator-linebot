import json
import logging
import os
from typing import Any

import boto3
from linebot import LineBotApi, WebhookHandler
from linebot.exceptions import InvalidSignatureError
from linebot.models import MessageEvent, TextMessage, TextSendMessage

# Set up logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Environment variables
CHANNEL_ACCESS_TOKEN = os.environ.get("LINE_CHANNEL_ACCESS_TOKEN")
CHANNEL_SECRET = os.environ.get("LINE_CHANNEL_SECRET")
BEDROCK_REGION = os.environ.get("BEDROCK_REGION")
BEDROCK_MODEL_ID = os.environ.get("BEDROCK_MODEL_ID")

# Initialize LINE Bot API and Webhook Handler
line_bot_api = LineBotApi(CHANNEL_ACCESS_TOKEN) if CHANNEL_ACCESS_TOKEN else None
handler = WebhookHandler(CHANNEL_SECRET) if CHANNEL_SECRET else None

# Initialize Bedrock client
bedrock_client = boto3.client("bedrock-runtime", region_name=BEDROCK_REGION)


class TranslationService:
    """Service for handling translation using Amazon Bedrock"""

    def __init__(self, bedrock_client: Any) -> None:
        self.bedrock_client = bedrock_client

    def translate_text(
        self, text: str, source_lang: str, target_lang: str
    ) -> Any | None:
        """Translate text using Amazon Bedrock Claude model"""
        try:
            # Prepare the translation prompt
            if target_lang == "en":
                prompt = f"Translate the following text to English. Only provide the translation, no explanations:\n\n{text}"
            else:
                prompt = f"Translate the following text to Japanese. Only provide the translation, no explanations:\n\n{text}"

            body = {"messages": [{"role": "user", "content": [{"text": prompt}]}]}

            response = self.bedrock_client.invoke_model(
                modelId=BEDROCK_MODEL_ID,
                body=json.dumps(body),
                contentType="application/json",
            )

            response_body = json.loads(response["body"].read())
            translated_text = response_body["output"]["message"]["content"][0][
                "text"
            ].strip()

            return translated_text

        except Exception as e:
            logger.error(f"Translation failed: {e}")
            return None


def process_message_event(
    event: MessageEvent, translation_service: TranslationService
) -> str | None:
    """Process a message event and return translation if needed"""
    try:
        # Check if message is a text message
        if not isinstance(event.message, TextMessage):
            return None

        # Check if line_bot_api is initialized
        if line_bot_api is None:
            logger.error("LINE Bot API not initialized")
            return "Bot configuration error"

        # Get user's profile display name
        user_profile = line_bot_api.get_profile(event.source.user_id)
        user_display_name = user_profile.display_name

        message_text = event.message.text.strip()

        # Check for translation triggers
        if "#e2j" in message_text.lower():
            # English to Japanese translation
            text_to_translate = (
                message_text.replace("#e2j", "").replace("#E2J", "").strip()
            )
            source_lang = "en"
            target_lang = "ja"
        elif "#j2e" in message_text.lower():
            # Japanese to English translation
            text_to_translate = (
                message_text.replace("#j2e", "").replace("#J2E", "").strip()
            )
            source_lang = "ja"
            target_lang = "en"
        else:
            return None

        if text_to_translate:
            logger.info(
                f"Translating from {source_lang} to {target_lang}: {text_to_translate}"
            )

            # Translate the text
            translated_text = translation_service.translate_text(
                text_to_translate, source_lang, target_lang
            )

            return f"Message from @{user_display_name}: ({source_lang} -> {target_lang}):\n--------------------\n{translated_text}"

        return None

    except Exception as e:
        logger.error(f"Error processing message: {e}")
        return "An error occurred while processing your message."


def lambda_handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    """AWS Lambda handler function"""
    logger.info(event)

    # Check if required components are initialized
    if line_bot_api is None or handler is None:
        error_message = "LINE Bot not properly configured. Check environment variables."
        logger.error(error_message)
        return {"statusCode": 500, "body": json.dumps(error_message)}

    signature = event["headers"]["x-line-signature"]
    body = event["body"]

    # Initialize translation service
    translation_service = TranslationService(bedrock_client)

    @handler.add(MessageEvent, message=TextMessage)  # type: ignore
    def handle_message(event: MessageEvent) -> None:
        # Process the message for translation
        reply_text = process_message_event(event, translation_service)

        if reply_text:
            # Send translation response
            line_bot_api.reply_message(
                event.reply_token, TextSendMessage(text=reply_text)
            )
        else:
            # Optional: You can choose to not respond if no translation trigger is found
            # or echo back the original message
            pass

    response = {"statusCode": 200, "body": json.dumps("OK")}

    try:
        handler.handle(body, signature)
    except InvalidSignatureError:
        error_message = (
            "Invalid signature. Please check your channel access token channel secret."
        )

        logger.error(error_message)
        response["statusCode"] = 502
        response["body"] = json.dumps(error_message)

    return response
