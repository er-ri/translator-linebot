# LINE Bot Translator

A serverless LINE bot that automatically translates messages between English and Japanese using AWS Lambda and Amazon Bedrock.

## Features

- **Bidirectional Translation**: Translates English to Japanese and Japanese to English
- **Mention-based Activation**: Bot responds only when user's input contains `#ej2` or `#j2e`
- **Serverless Architecture**: Runs on AWS Lambda for scalability and cost-effectiveness
- **AI-Powered Translation**: Uses Amazon Bedrock's model for high-quality translations

## Project Structure

```
translator-linebot/
├── lambda_function.py              # Main Lambda handler with translation logic
├── requirements.txt                # Python dependencies
├── cloudformation-template.yaml    # Infrastructure as Code template
├── deploy.sh                      # Automated deployment script
├── .env.example                   # Environment variables template
├── .gitignore                     # Git ignore patterns
└── README.md                      # This documentation
```

## Prerequisites

- AWS Account with access to:
  - AWS Lambda
  - Amazon Bedrock
  - IAM (for role management)
- LINE Developers Account
- Python 3.12+ (for local development)
- AWS CLI configured with appropriate credentials

## Setup Instructions

### 1. LINE Bot Configuration

1. **Create a LINE Channel**:

   - Go to [LINE Developers Console](https://developers.line.biz/console/)
   - Create a new provider or use an existing one
   - Create a new Messaging API channel
   - Note down your `Channel Access Token` and `Channel Secret`

2. **Configure Webhook**:
   - In your LINE channel settings, enable "Use webhook"
   - Set the webhook URL to your API Gateway URL (you'll get this after deployment)

### 2. Development Setup

1. **Clone the repository**:

   ```bash
   git clone <repository-url>
   cd translator-linebot
   ```

2. **Create virtual environment**:

   ```bash
   uv sync
   uv run pre-commit install  # (Optional) Install pre-commit hooks
   source venv/bin/activate  # On Windows: venv\Scripts\activate
   ```

3. **Configure environment variables**:

   ```bash
   cp .env.example .env
   # Edit .env file with your actual values
   ```

4. **Run the deployment script**:

   ```bash
   ./deploy.sh --update-layer
   ```

   > The argument `--update-layer` will only need to added for the first deployment or when dependencies change.

5. **Update LINE Webhook URL**:

   - Copy your Lambda Function URL
   - Go to LINE Developers Console
   - Set the webhook URL to your Lambda Function URL
   - Test the webhook connection

6. **Add Bot to LINE Group/Chat**:
   - Add your bot to a LINE group or chat
   - The bot will respond when the message contains with `#e2j` or `#j2e`

## Architecture

```
LINE Message -> Lambda Function -> Bedrock -> Lambda Response -> LINE Reply
```

## License

This project is licensed under the MIT License.
