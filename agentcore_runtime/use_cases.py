"""Pure Clean Architecture use case for retrieval-only grounded Q&A (Controls C4, C6, C7, C8)."""

from dataclasses import dataclass, field
from typing import Protocol


@dataclass(frozen=True)
class RetrievedChunk:
    text: str
    source_uri: str


@dataclass(frozen=True)
class GuardrailVerdict:
    intervened: bool
    message: str = ""


@dataclass(frozen=True)
class GroundedAnswer:
    answer: str
    guardrail_action: str
    sources: tuple[str, ...] = field(default_factory=tuple)
    grounded: bool = True

    def to_dict(self) -> dict:
        return {
            "answer": self.answer,
            "guardrail_action": self.guardrail_action,
            "sources": list(self.sources),
            "grounded": self.grounded,
        }


class GuardrailPort(Protocol):
    def check_input(self, text: str) -> GuardrailVerdict: ...


class KnowledgeBasePort(Protocol):
    def retrieve(self, query: str, user_id: str) -> list[RetrievedChunk]: ...


class MemoryPort(Protocol):
    def load_turns(self, user_id: str, session_id: str) -> list[dict]: ...
    def save_turn(self, user_id: str, session_id: str, prompt: str, answer: str) -> None: ...


class ModelPort(Protocol):
    def generate(self, prompt: str, chunks: list[RetrievedChunk], history: list[dict]) -> tuple[str, bool]: ...


class AnswerGroundedQuestionUseCase:
    """Retrieval-only agent: no write tools, enforced input/output guardrails, user-scoped memory."""

    def __init__(
        self,
        guardrail: GuardrailPort,
        knowledge_base: KnowledgeBasePort,
        memory: MemoryPort,
        model: ModelPort,
    ):
        self._guardrail = guardrail
        self._kb = knowledge_base
        self._memory = memory
        self._model = model

    def execute(self, user_id: str, session_id: str, prompt: str) -> GroundedAnswer:
        # C4: Input guardrail check (prompt attacks, denied topics, sensitive data).
        input_verdict = self._guardrail.check_input(prompt)
        if input_verdict.intervened:
            return GroundedAnswer(
                answer=input_verdict.message or "Request blocked by input guardrail.",
                guardrail_action="INTERVENED",
                sources=(),
                grounded=False,
            )

        # C8: Load memory strictly scoped to verified user_id + session_id.
        history = self._memory.load_turns(user_id=user_id, session_id=session_id)

        # C5/C6: Retrieve approved knowledge chunks (retrieval-only, no write tools).
        chunks = self._kb.retrieve(query=prompt, user_id=user_id)
        sources: list[str] = []
        for chunk in chunks:
            if chunk.source_uri and chunk.source_uri not in sources:
                sources.append(chunk.source_uri)

        # C6/C7: Generate grounded answer with output guardrails & contextual grounding.
        answer, output_intervened = self._model.generate(
            prompt=prompt,
            chunks=chunks,
            history=history,
        )

        # C8: Persist turn to user-scoped AgentCore Memory.
        if not output_intervened:
            self._memory.save_turn(
                user_id=user_id,
                session_id=session_id,
                prompt=prompt,
                answer=answer,
            )

        return GroundedAnswer(
            answer=answer,
            guardrail_action="INTERVENED" if output_intervened else "NONE",
            sources=tuple(sources),
            grounded=bool(chunks) and not output_intervened,
        )
