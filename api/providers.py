from dataclasses import dataclass
from typing import Any

@dataclass
class ProviderResult:
    provider: str
    success: bool
    data: dict[str, Any]
    confidence: float = 0.0

class TelecomProvider:
    name = "base"
    async def lookup(self, e164: str) -> ProviderResult:
        raise NotImplementedError

class MockProvider(TelecomProvider):
    name = "mock"
    async def lookup(self, e164: str) -> ProviderResult:
        return ProviderResult(
            provider=self.name,
            success=True,
            data={"line_type": "unknown", "reachable": None},
            confidence=0.25,
        )

class WaterfallVerifier:
    def __init__(self, providers: list[TelecomProvider]):
        self.providers = providers

    async def verify(self, e164: str) -> dict[str, Any]:
        results = []
        for provider in self.providers:
            try:
                result = await provider.lookup(e164)
                results.append(result)
            except Exception as exc:
                results.append(ProviderResult(provider.name, False, {"error": str(exc)}, 0))
        successful = [r for r in results if r.success]
        consensus = {}
        for key in ("line_type", "reachable", "current_carrier", "ported", "reassigned"):
            votes = {}
            for r in successful:
                value = r.data.get(key)
                if value is not None:
                    votes[value] = votes.get(value, 0) + r.confidence
            if votes:
                consensus[key] = max(votes, key=votes.get)
        confidence = min(0.99, max((r.confidence for r in successful), default=0))
        return {
            "results": [r.__dict__ for r in results],
            "consensus": consensus,
            "confidence": confidence,
        }
