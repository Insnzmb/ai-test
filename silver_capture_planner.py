#!/usr/bin/env python3
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any


@dataclass
class CapturePacket:
    should_try_catch: bool = False
    target_species: int = 0
    note: str = ''
    scores: dict[str, float] = field(default_factory=dict)

    def to_prompt_dict(self) -> dict[str, Any]:
        return {
            'should_try_catch': self.should_try_catch,
            'target_species': self.target_species,
            'note': self.note,
        }


class CapturePlannerRuntime:
    def __init__(self) -> None:
        self.attempted_species: dict[int, int] = {}
        self.caught_bias: dict[int, float] = {}

    def observe_outcome(self, prev_state: dict[str, Any], action: str, curr_state: dict[str, Any], reward_signal: Any | None = None) -> None:
        if int(prev_state.get('battle_mode', 0)) == 0:
            return
        species = int(prev_state.get('enemy_species', 0) or 0)
        if species <= 0:
            return
        if action == 'A':
            self.attempted_species[species] = int(self.attempted_species.get(species, 0)) + 1
        progress = bool(getattr(reward_signal, 'progress', False)) if reward_signal is not None else False
        if int(prev_state.get('battle_mode', 0)) != 0 and int(curr_state.get('battle_mode', 0)) == 0 and progress:
            self.caught_bias[species] = min(3.0, float(self.caught_bias.get(species, 0.0)) + 0.4)

    def plan(self, state: dict[str, Any], progress_snapshot: Any) -> CapturePacket:
        pkt = CapturePacket()
        if int(state.get('battle_mode', 0)) == 0:
            return pkt
        species = int(state.get('enemy_species', 0) or 0)
        if species <= 0:
            return pkt
        balls = int(state.get('balls', 0) or 0)
        enemy_hp = int(state.get('enemy_hp', 0) or 0)
        planner = str(getattr(progress_snapshot, 'active_planner', 'story') or 'story')
        is_wild = int(state.get('battle_type', 0) or 0) in (0, 1, 2)
        attempts = int(self.attempted_species.get(species, 0))
        bias = float(self.caught_bias.get(species, 0.0))

        if not is_wild or balls <= 0:
            return pkt

        should = planner == 'catch' or enemy_hp <= 30 or attempts <= 1
        pkt.should_try_catch = should
        pkt.target_species = species
        pkt.note = (
            f'Species {species} wild encounter. Balls={balls}, HP={enemy_hp}, attempts={attempts}. '
            'Try to catch aggressively when low HP or when the catch planner is active.'
        )
        if should:
            pkt.scores['A'] = pkt.scores.get('A', 0.0) + (1.5 if enemy_hp <= 30 else 0.8) + bias
            pkt.scores['DOWN'] = pkt.scores.get('DOWN', 0.0) + 0.25
            pkt.scores['LEFT'] = pkt.scores.get('LEFT', 0.0) + 0.2
            pkt.scores['NONE'] = pkt.scores.get('NONE', 0.0) - 0.9
        return pkt
