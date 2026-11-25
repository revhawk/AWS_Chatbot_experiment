"""Layer 4 Composition Root: Wires AWS adapters into Clean Architecture Use Cases."""

import os
import boto3

from backend.adapters.ai.agentcore_gateway import AgentCoreRuntimeGateway
from backend.adapters.auth.jwks_verifier import JwksTokenVerifier
from backend.adapters.controllers.apigw_controller import ApiGatewayController
from backend.adapters.persistence.dynamodb_gateway import DynamoDbGateway
from backend.use_cases.ask_question import AskQuestionUseCase
from backend.use_cases.submit_feedback import SubmitFeedbackUseCase

_CONTROLLER = None


def _build_controller() -> ApiGatewayController:
    region = os.environ["AWS_REGION"]
    verifier = JwksTokenVerifier(
        issuer=os.environ["ENTRA_ISSUER"],
        audience=os.environ["ENTRA_AUDIENCE"],
        jwks_url=os.environ["ENTRA_JWKS_URL"],
    )
    agentcore_client = boto3.client("bedrock-agentcore", region_name=region)
    runtime_gateway = AgentCoreRuntimeGateway(
        agentcore_client=agentcore_client,
        runtime_arn=os.environ["AGENTCORE_RUNTIME_ARN"],
    )
    ddb_table = boto3.resource("dynamodb", region_name=region).Table(os.environ["TABLE_NAME"])
    ddb_gateway = DynamoDbGateway(table=ddb_table)

    return ApiGatewayController(
        ask_use_case=AskQuestionUseCase(
            token_verifier=verifier,
            agent_runtime=runtime_gateway,
            audit_logger=ddb_gateway,
        ),
        feedback_use_case=SubmitFeedbackUseCase(
            token_verifier=verifier,
            feedback_store=ddb_gateway,
        ),
    )


def lambda_handler(event: dict, context) -> dict:
    global _CONTROLLER
    if _CONTROLLER is None:
        _CONTROLLER = _build_controller()
    return _CONTROLLER.handle(event)
