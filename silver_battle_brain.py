#!/usr/bin/env python3
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any


@dataclass
class BattlePacket:
    recommended_action: str | None = None
    target_menu: str = ''
    note: str = ''
    scores: dict[str, float] = field(default_factory=dict)

    def to_prompt_dict(self) -> dict[str, Any]:
        return {
            'recommended_action': self.recommended_action,
            'target_menu': self.target_menu,
            'note': self.note,
        }


class BattleBrainRuntime:
    MENU_TARGETS = {
        'FIGHT': 0,
        'PKMN': 1,
        'PACK': 2,
        'RUN': 3,
    }

    def _menu_step(self, current: int, target: int) -> str:
        # Classic 2x2 battle menu guess.
        if current == target:
            return 'A'
        current = max(0, min(3, int(current)))
        if current in (0, 1) and target in (2, 3):
            return 'DOWN'
        if current in (2, 3) and target in (0, 1):
            return 'UP'
        if current in (0, 2) and target in (1, 3):
            return 'RIGHT'
        if current in (1, 3) and target in (0, 2):
            return 'LEFT'
        return 'A'

    def choose(self, state: dict[str, Any], progress_snapshot: Any, planner_packet: Any | None = None) -> BattlePacket:
        pkt = BattlePacket()
        if int(state.get('battle_mode', 0)) == 0:
            return pkt

        balls = int(state.get('balls', 0) or 0)
        enemy_hp = int(state.get('enemy_hp', 0) or 0)
        battle_type = int(state.get('battle_type', 0) or 0)
        menu_pos = int(state.get('battle_menu_pos', 0) or 0)
        route_planner = str(getattr(progress_snapshot, 'active_planner', 'story') or 'story')
        low_hp_party = bool(getattr(progress_snapshot, 'low_hp_party', False))
        strongest = int(getattr(progress_snapshot, 'strongest_level', 0) or 0)

        is_wild = battle_type in (0, 1, 2)
        catch_mode = is_wild and balls > 0 and route_planner == 'catch'

        def add(action: str, value: float) -> None:
            pkt.scores[action] = pkt.scores.get(action, 0.0) + value

        # If menus/scripts are already deep, A/B are the least dangerous generic moves.
        add('A', 0.35)
        add('B', 0.08)

        if catch_mode:
            pkt.target_menu = 'PACK'
            pkt.note = 'Wild battle with catch planner active: route to PACK and throw balls when the menu aligns.'
            desired = self.MENU_TARGETS['PACK']
            step = self._menu_step(menu_pos, desired)
            pkt.recommended_action = step
            add(step, 2.1 if enemy_hp <= 30 else 1.35)
            add('A', 0.9 if menu_pos == desired else 0.0)
            add('DOWN', 0.35)
            add('LEFT', 0.25)
            add('RIGHT', 0.15)
            add('NONE', -1.1)
            return pkt

        if low_hp_party and not is_wild:
            pkt.target_menu = 'PKMN'
            pkt.note = 'Trainer battle with low HP pressure: bias toward party management if the menu cooperates.'
            step = self._menu_step(menu_pos, self.MENU_TARGETS['PKMN'])
            pkt.recommended_action = step
            add(step, 1.25)
            add('A', 0.6 if menu_pos == self.MENU_TARGETS['PKMN'] else 0.0)
            add('NONE', -0.8)
            return pkt

        pkt.target_menu = 'FIGHT'
        pkt.note = 'Default battle policy: push the fight menu and confirm productive attacks.'
        step = self._menu_step(menu_pos, self.MENU_TARGETS['FIGHT'])
        pkt.recommended_action = step
        add(step, 1.9)
        add('A', 1.2 if menu_pos == self.MENU_TARGETS['FIGHT'] else 0.0)
        add('B', -0.35 if not is_wild else 0.0)
        add('NONE', -1.0)
        if strongest >= 45 and not is_wild:
            add('A', 0.3)
        return pkt
