"""Offline contract checks for api/providers.py (never calls paid providers)."""
from __future__ import annotations

import asyncio
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from api.providers import MockProvider, ProviderResult, TelecomProvider, WaterfallVerifier


class FixedProvider(TelecomProvider):
    def __init__(self, name: str, data: dict, confidence: float, calls: list[str], fails: bool = False):
        self.name = name
        self.data = data
        self.confidence = confidence
        self.calls = calls
        self.fails = fails

    async def lookup(self, e164: str) -> ProviderResult:
        self.calls.append(f"{self.name}:{e164}")
        if self.fails:
            raise TimeoutError("offline test provider timeout")
        return ProviderResult(self.name, True, self.data, self.confidence)


async def main() -> None:
    mock = await MockProvider().lookup("+14155550132")
    calls: list[str] = []
    providers = [
        FixedProvider("first", {"reachable": False, "line_type": "mobile"}, 0.4, calls),
        FixedProvider("timeout", {}, 0.0, calls, fails=True),
        FixedProvider("last", {"reachable": True, "line_type": "mobile"}, 0.8, calls),
    ]
    result = await WaterfallVerifier(providers).verify("+14155550132")
    print(json.dumps({
        "mock": mock.__dict__,
        "provider_order": [row["provider"] for row in result["results"]],
        "calls": calls,
        "success": [row["success"] for row in result["results"]],
        "consensus": result["consensus"],
        "confidence": result["confidence"],
    }))


if __name__ == "__main__":
    asyncio.run(main())
