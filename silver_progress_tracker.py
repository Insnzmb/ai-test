#!/usr/bin/env python3
from __future__ import annotations

from dataclasses import dataclass, field, asdict
from typing import Any

NUM_POKEMON = 251

JOHTO_BADGE_ORDER = [
    "Falkner",
    "Bugsy",
    "Whitney",
    "Morty",
    "Chuck",
    "Jasmine",
    "Pryce",
    "Clair",
]
KANTO_BADGE_ORDER = [
    "Lt. Surge",
    "Sabrina",
    "Erika",
    "Janine",
    "Misty",
    "Brock",
    "Blaine",
    "Blue",
]


@dataclass
class Milestone:
    key: str
    label: str
    planner: str
    priority: int
    entry_hint: str = ""
    success_hint: str = ""
    fallback_hint: str = ""


@dataclass
class ProgressSnapshot:
    map_name: str
    story_phase: str
    johto_badges: int
    kanto_badges: int
    elite_four_done: bool
    red_done: bool
    dex_caught: int
    dex_seen: int
    num_items: int
    num_key_items: int
    balls: int
    party_count: int
    avg_level: float
    strongest_level: int
    low_hp_party: bool
    active_planner: str
    milestone_key: str
    milestone_label: str
    objective_summary: str
    completion_percent: float
    route_class: str
    needs_recovery: bool = False
    blocked: list[str] = field(default_factory=list)
    subgoals: dict[str, float] = field(default_factory=dict)

    def to_prompt_dict(self) -> dict[str, Any]:
        payload = asdict(self)
        payload["completion_percent"] = round(float(self.completion_percent), 2)
        payload["avg_level"] = round(float(self.avg_level), 2)
        return payload


class TelemetryReaders:
    """Tiny semantic wrappers over raw emulator telemetry.

    This does not replace the raw state dict; it just gives the new planner code
    a sane, reusable place to interpret it. Less spaghetti, fewer haunted onions.
    """

    @staticmethod
    def badge_count(raw: int) -> int:
        return int(raw or 0).bit_count()

    @staticmethod
    def party_levels(state: dict[str, Any]) -> list[int]:
        out: list[int] = []
        for item in list(state.get("party_detail", []) or []):
            try:
                level = int(item.get("level", 0) or 0)
            except Exception:
                level = 0
            if level > 0:
                out.append(level)
        return out

    @staticmethod
    def party_low_hp(state: dict[str, Any]) -> bool:
        for item in list(state.get("party_detail", []) or []):
            try:
                hp = int(item.get("hp", 0) or 0)
                max_hp = int(item.get("max_hp", 0) or 0)
            except Exception:
                continue
            if max_hp > 0 and hp / max_hp <= 0.25:
                return True
        return False

    @staticmethod
    def route_class(map_name: str) -> str:
        name = (map_name or "").upper()
        if any(token in name for token in ("TOWN", "CITY", "LAB", "CENTER", "MART", "HOUSE", "RADIO")):
            return "town"
        if any(token in name for token in ("ROUTE", "ROAD", "GATE")):
            return "route"
        if any(token in name for token in ("CAVE", "TOWER", "WELL", "DEN", "PATH", "MT_", "VICTORY")):
            return "dungeon"
        if any(token in name for token in ("GYM",)):
            return "gym"
        if any(token in name for token in ("SEA", "ISLAND", "WHIRL", "HARBOR", "PORT")):
            return "water"
        return "unknown"


class ProgressTrackerRuntime:
    def __init__(self) -> None:
        self.last_snapshot: ProgressSnapshot | None = None
        self.last_milestone_key: str = ""
        self.milestone_streak: int = 0
        self.maps_seen: set[str] = set()

    def _story_phase(self, state: dict[str, Any], map_name: str) -> str:
        johto = TelemetryReaders.badge_count(state.get("badges_johto", 0))
        kanto = TelemetryReaders.badge_count(state.get("badges_kanto", 0))
        if johto == 0 and int(state.get("party_count", 0)) <= 1:
            return "intro"
        if johto < 8:
            return "johto"
        if not int(state.get("beat_elite_four", 0)):
            return "league"
        if kanto < 8:
            return "kanto"
        if not int(state.get("beat_red", 0)):
            return "mt_silver"
        return "cleanup"

    def _milestone(self, state: dict[str, Any], map_name: str) -> Milestone:
        johto = TelemetryReaders.badge_count(state.get("badges_johto", 0))
        kanto = TelemetryReaders.badge_count(state.get("badges_kanto", 0))
        beat_e4 = bool(int(state.get("beat_elite_four", 0)))
        beat_red = bool(int(state.get("beat_red", 0)))
        caught = int(state.get("dex_caught", 0) or 0)
        route_class = TelemetryReaders.route_class(map_name)
        name = (map_name or "").upper()

        if johto == 0:
            if "ELMS_LAB" in name and int(state.get("party_count", 0)) <= 1:
                return Milestone("starter", "Claim starter and leave Elm's Lab", "story", 100, "In Elm's Lab with no progress yet", "Party established and Route 29 progress begins", "Use A to advance lab dialogue and accept the starter.")
            return Milestone("intro_leave_home", "Finish intro and begin Route 29", "story", 99, "Still in home / New Bark intro state", "Map progression out of intro and starter acquired", "Use A/START to clear intro and move out of the house.")
        if johto < 8:
            badge_name = JOHTO_BADGE_ORDER[min(johto, len(JOHTO_BADGE_ORDER) - 1)]
            return Milestone(f"johto_badge_{johto+1}", f"Earn Johto badge {johto+1}: {badge_name}", "story", 90 - johto, "Johto gym campaign incomplete", f"Johto badge count increases past {johto}", "Push story gates, items, training, and the next gym route.")
        if not beat_e4:
            return Milestone("elite_four", "Clear Victory Road and beat the Elite Four", "story", 70, "All Johto badges obtained", "Elite Four completion flag set", "Train, route to Victory Road, and confirm battle progress with A.")
        if kanto < 8:
            badge_name = KANTO_BADGE_ORDER[min(kanto, len(KANTO_BADGE_ORDER) - 1)]
            return Milestone(f"kanto_badge_{kanto+1}", f"Earn Kanto badge {kanto+1}: {badge_name}", "story", 50 - kanto, "Kanto open but not complete", f"Kanto badge count increases past {kanto}", "Travel, interact, and clear Kanto gym access gates.")
        if not beat_red:
            return Milestone("red", "Climb Mt. Silver and defeat Red", "story", 25, "All badges earned", "Red defeated flag set", "Train to high levels and push Mt. Silver upward.")
        if caught < NUM_POKEMON:
            return Milestone("dex_cleanup", f"Catch remaining Pokémon ({caught}/{NUM_POKEMON})", "catch", 15, "Main story complete", "Dex caught count reaches 251", "Seek wild encounters, fish, surf, and breed for missing species.")
        if route_class in {"town", "dungeon", "route", "water"}:
            return Milestone("item_cleanup", "Collect remaining reachable items", "item", 10, "Postgame cleanup", "Item counts continue improving", "Interact with obvious pickups and side paths.")
        return Milestone("free_explore", "Explore safely without stalling", "story", 1, "Nothing urgent left", "Continue safe movement and interaction", "Avoid loops and keep collecting useful progress.")

    def _planner_scores(self, state: dict[str, Any], milestone: Milestone, avg_level: float) -> tuple[str, dict[str, float], list[str]]:
        johto = TelemetryReaders.badge_count(state.get("badges_johto", 0))
        kanto = TelemetryReaders.badge_count(state.get("badges_kanto", 0))
        caught = int(state.get("dex_caught", 0) or 0)
        seen = int(state.get("dex_seen", 0) or 0)
        balls = int(state.get("balls", 0) or 0)
        low_hp = TelemetryReaders.party_low_hp(state)
        blocked: list[str] = []
        subgoals = {
            "story": 0.0,
            "catch": 0.0,
            "train": 0.0,
            "item": 0.0,
            "breed": 0.0,
        }
        subgoals["story"] = 3.2 if milestone.planner == "story" else 1.0
        subgoals["catch"] = 1.2 + max(0.0, min(2.0, (seen - caught) / 40.0))
        if balls <= 0:
            subgoals["catch"] *= 0.45
            blocked.append("low_balls")
        target_level = 8 + (johto * 4) + (kanto * 3)
        if not int(state.get("beat_elite_four", 0)):
            target_level = max(target_level, 38 if johto >= 8 else target_level)
        if not int(state.get("beat_red", 0)) and int(state.get("beat_elite_four", 0)):
            target_level = max(target_level, 58)
        train_gap = max(0.0, target_level - avg_level)
        subgoals["train"] = 0.8 + min(3.0, train_gap / 6.0)
        if low_hp:
            blocked.append("party_low_hp")
            subgoals["train"] += 0.4
        item_growth = int(state.get("num_key_items", 0) or 0) * 0.12 + int(state.get("num_items", 0) or 0) * 0.015
        subgoals["item"] = 0.7 + min(2.2, item_growth / 5.0)
        subgoals["breed"] = 0.4
        if johto >= 3 and caught < NUM_POKEMON:
            subgoals["breed"] = 0.95
        active = max(subgoals.items(), key=lambda kv: kv[1])[0]
        if milestone.planner in subgoals:
            subgoals[milestone.planner] += 0.55
            active = max(subgoals.items(), key=lambda kv: kv[1])[0]
        return active, subgoals, blocked

    def build_snapshot(self, state: dict[str, Any], map_name: str) -> ProgressSnapshot:
        self.maps_seen.add(map_name)
        levels = TelemetryReaders.party_levels(state)
        avg_level = (sum(levels) / len(levels)) if levels else 0.0
        strongest = max(levels) if levels else 0
        phase = self._story_phase(state, map_name)
        milestone = self._milestone(state, map_name)
        active_planner, subgoals, blocked = self._planner_scores(state, milestone, avg_level)
        completion = (
            TelemetryReaders.badge_count(state.get("badges_johto", 0)) * 4.0
            + TelemetryReaders.badge_count(state.get("badges_kanto", 0)) * 2.6
            + (12.0 if int(state.get("beat_elite_four", 0)) else 0.0)
            + (8.0 if int(state.get("beat_red", 0)) else 0.0)
            + min(14.0, int(state.get("dex_caught", 0) or 0) / 18.0)
        )
        completion = max(0.0, min(100.0, completion))
        route_class = TelemetryReaders.route_class(map_name)
        needs_recovery = low_hp = TelemetryReaders.party_low_hp(state)
        snap = ProgressSnapshot(
            map_name=map_name,
            story_phase=phase,
            johto_badges=TelemetryReaders.badge_count(state.get("badges_johto", 0)),
            kanto_badges=TelemetryReaders.badge_count(state.get("badges_kanto", 0)),
            elite_four_done=bool(int(state.get("beat_elite_four", 0))),
            red_done=bool(int(state.get("beat_red", 0))),
            dex_caught=int(state.get("dex_caught", 0) or 0),
            dex_seen=int(state.get("dex_seen", 0) or 0),
            num_items=int(state.get("num_items", 0) or 0),
            num_key_items=int(state.get("num_key_items", 0) or 0),
            balls=int(state.get("balls", 0) or 0),
            party_count=int(state.get("party_count", 0) or 0),
            avg_level=avg_level,
            strongest_level=strongest,
            low_hp_party=low_hp,
            active_planner=active_planner,
            milestone_key=milestone.key,
            milestone_label=milestone.label,
            objective_summary=f"{milestone.label}. Active planner: {active_planner}.",
            completion_percent=completion,
            route_class=route_class,
            needs_recovery=needs_recovery,
            blocked=blocked,
            subgoals=subgoals,
        )
        if snap.milestone_key == self.last_milestone_key:
            self.milestone_streak += 1
        else:
            self.last_milestone_key = snap.milestone_key
            self.milestone_streak = 1
        self.last_snapshot = snap
        return snap
