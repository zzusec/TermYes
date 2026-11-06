#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Sources" / "TermYesApp.swift").read_text()

assert "状态详情" not in SOURCE, "状态详情 must be removed, not renamed"
assert "hideDashboardIfVisible" not in SOURCE, "Switching apps must leave Terminal at standard window level instead of hiding it"
assert "MenuPresentation.detailsAlert" in SOURCE
assert "agentMenuEntries" in SOURCE
assert "更多 Agent" in SOURCE
print("menu copy checks passed: 状态详情 removed; details stay in bounded alerts")
