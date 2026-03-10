#!/usr/bin/env python3
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

MOVEMENT_ACTIONS = {"UP", "DOWN", "LEFT", "RIGHT", "UP_A", "DOWN_A", "LEFT_A", "RIGHT_A"}


@dataclass
class MissionPacket:
    key: str = ''
    label: str = ''
    objective_note: str = ''
    guide_hint: str = ''
    scores: dict[str, float] = field(default_factory=dict)
    critical_gate: bool = False

    def to_prompt_dict(self) -> dict[str, Any]:
        return {
            'key': self.key,
            'label': self.label,
            'objective_note': self.objective_note,
            'guide_hint': self.guide_hint,
            'critical_gate': self.critical_gate,
        }


class MissionScriptRuntime:
    """Exact-ish mission handlers for the ugly progression choke points.

    Not tile-perfect. It is targeted pressure for places where Pokémon Silver
    loves to become a bureaucratic labyrinth with bushes.
    """

    def _packet(self, key: str, label: str, note: str, guide_hint: str = '', critical: bool = True) -> MissionPacket:
        return MissionPacket(key=key, label=label, objective_note=note, guide_hint=guide_hint, critical_gate=critical)

    def script(self, state: dict[str, Any], map_name: str, progress_snapshot: Any, *, guide_action: str | None = None, fallback_action: str | None = None) -> MissionPacket:
        name = (map_name or '').upper()
        johto = int(getattr(progress_snapshot, 'johto_badges', 0) or 0)
        kanto = int(getattr(progress_snapshot, 'kanto_badges', 0) or 0)
        beat_e4 = bool(getattr(progress_snapshot, 'elite_four_done', False))
        beat_red = bool(getattr(progress_snapshot, 'red_done', False))
        pkt = MissionPacket(guide_hint=str(guide_action or fallback_action or 'NONE'))

        def push(action: str | None, amount: float) -> None:
            if action and action != 'NONE':
                pkt.scores[action] = pkt.scores.get(action, 0.0) + amount

        # Goldenrod / Whitney / SquirtBottle line -> Sudowoodo gate.
        if johto == 2 and any(token in name for token in ('GOLDENROD', 'FLOWER', 'GYM')):
            pkt = self._packet(
                'goldenrod_whitney',
                'Clear Whitney line and get access to the SquirtBottle path',
                'Whitney is the classic progress troll. Use A to push gym dialogue, then route toward the Flower Shop/SquirtBottle chain that leads to Sudowoodo.',
                guide_hint=str(guide_action or 'A'),
            )
            push('A', 1.9)
            push(guide_action, 1.2)
            push(fallback_action, 0.8)
            return pkt
        if johto == 2 and any(token in name for token in ('ROUTE_35', 'ROUTE_36', 'ROUTE_37', 'NATIONAL_PARK')):
            pkt = self._packet(
                'sudowoodo_gate',
                'Clear the Sudowoodo roadblock and reach Ecruteak',
                'The post-Whitney route is National Park -> Route 36 -> Sudowoodo -> Route 37 -> Ecruteak. Interact with A when blocked by the weird fake-tree goblin.',
                guide_hint=str(guide_action or 'RIGHT'),
            )
            push('A', 1.8)
            push(guide_action, 1.5)
            push(fallback_action, 1.0)
            return pkt

        # Olivine lighthouse / medicine / Jasmine.
        if 4 <= johto <= 5 and any(token in name for token in ('OLIVINE', 'LIGHTHOUSE', 'CIANWOOD', 'ROUTE_40', 'ROUTE_41')):
            pkt = self._packet(
                'amphy_medicine',
                'Fix the lighthouse medicine chain and unlock Jasmine cleanly',
                'This gate is Lighthouse -> Cianwood medicine -> back to Olivine Gym. Bias surf-route movement and talk/confirm actions in the lighthouse and city interiors.',
                guide_hint=str(guide_action or fallback_action or 'A'),
            )
            push('A', 1.45)
            push(guide_action, 1.35)
            push(fallback_action, 1.05)
            return pkt

        # Mahogany / Rocket Hideout.
        if 6 <= johto <= 7 and any(token in name for token in ('MAHOGANY', 'ROCKET_HIDEOUT', 'LAKE_OF_RAGE', 'ROUTE_43')):
            pkt = self._packet(
                'mahogany_rocket',
                'Clear Lake of Rage and the Rocket Hideout to reopen story progression',
                'Use A often in Mahogany/Hideout interiors. This segment is script-heavy and hates hesitation.',
                guide_hint=str(guide_action or 'A'),
            )
            push('A', 1.7)
            push(guide_action, 1.25)
            return pkt

        # Radio Tower takeover after Pryce.
        if johto >= 7 and not beat_e4 and any(token in name for token in ('GOLDENROD', 'RADIO_TOWER', 'UNDERGROUND')):
            pkt = self._packet(
                'radio_tower',
                'Clear the Radio Tower / Underground Team Rocket arc',
                'After Pryce the story shoves you through Goldenrod Radio Tower and Underground access. Favor A in interiors and guided movement over dithering.',
                guide_hint=str(guide_action or 'A'),
            )
            push('A', 1.9)
            push(guide_action, 1.1)
            push(fallback_action, 0.9)
            return pkt

        # Blackthorn / Dragon Den / Waterfall.
        if johto == 8 and not beat_e4 and any(token in name for token in ('BLACKTHORN', 'DRAGON', 'ICE_PATH', 'ROUTE_44', 'ROUTE_45', 'ROUTE_46')):
            pkt = self._packet(
                'dragon_den',
                'Finish Blackthorn and the Dragon Den check so Waterfall progression opens',
                'This is the Clair/Dragon Den gate. Expect lots of A presses and route movement, then prep for Route 27/26/Victory Road.',
                guide_hint=str(guide_action or fallback_action or 'A'),
            )
            push('A', 1.65)
            push(guide_action, 1.3)
            push(fallback_action, 1.0)
            return pkt

        # League road.
        if johto == 8 and not beat_e4 and any(token in name for token in ('ROUTE_26', 'ROUTE_27', 'TOHJO', 'VICTORY_ROAD', 'INDIGO')):
            pkt = self._packet(
                'league_run',
                'Push Route 27/26, Tohjo Falls, Victory Road, and the Elite Four',
                'Waterfall is required in Tohjo Falls, and the route should stay aggressively story-focused until the League falls over.',
                guide_hint=str(guide_action or fallback_action or 'RIGHT'),
            )
            push(guide_action, 1.5)
            push(fallback_action, 1.25)
            return pkt

        # Kanto power plant / Snorlax / pass line.
        if beat_e4 and kanto < 8 and any(token in name for token in ('VERMILION', 'SAFFRON', 'LAVENDER', 'POWER_PLANT', 'CERULEAN', 'ROUTE_11', 'DIGLETT', 'ROUTE_2', 'PEWTER', 'ROUTE_12', 'ROUTE_16', 'ROUTE_17', 'ROUTE_18', 'FUCHSIA', 'CELADON', 'ROUTE_24', 'ROUTE_25')):
            pkt = self._packet(
                'kanto_unlocks',
                'Resolve Kanto unlock chains cleanly: Power Plant, Snorlax, Lost Item, train access, gym order cleanup',
                'Kanto is full of stateful errands. Favor NPC interactions and guided route movement instead of random tourism.',
                guide_hint=str(guide_action or 'A'),
            )
            push('A', 1.35)
            push(guide_action, 1.25)
            push(fallback_action, 1.05)
            return pkt

        # Mt. Silver / Red.
        if beat_e4 and kanto >= 8 and not beat_red and any(token in name for token in ('ROUTE_28', 'MT_SILVER', 'SILVER_CAVE')):
            pkt = self._packet(
                'mt_silver_red',
                'Climb Mt. Silver and challenge Red',
                'Mt. Silver is the final mountain bureaucracy. Guide movement matters, and summit contact is usually an A press away. Flash, Surf, and Waterfall help for full cave traversal.',
                guide_hint=str(guide_action or fallback_action or 'UP'),
            )
            push(guide_action, 1.55)
            push(fallback_action, 1.35)
            push('A', 0.75)
            return pkt

        pkt.key = 'none'
        pkt.label = 'No critical mission script active'
        pkt.objective_note = ''
        push(guide_action, 0.4)
        push(fallback_action, 0.25)
        return pkt
