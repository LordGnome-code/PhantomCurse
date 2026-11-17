# PhantomCurse

A dispel-aware group list for World of Warcraft: Forever. It lists your group
members and highlights debuffs your character can remove.

## Install

Copy the `PhantomCurse` folder into the game's `Interface\AddOns` folder. The
folder should contain `PhantomCurse.toc` and `PhantomCurse.lua` directly.
Restart the game or use `/reload`, then enable PhantomCurse in the AddOns list.

## Use

- Type `/pc` or `/phantomcurse` to see the available commands. The minimap
  dispel icon opens or hides the cleanse window with a left-click and opens
  settings with a right-click. Drag it around the minimap to reposition it.
  The addon also registers this icon in the native Addon Compartment for
  minimap icon-bag addons.
- Use `/pc minimap` to show or hide the minimap icon.
- Click a highlighted group member to target them, then use your normal
  dispel keybind. Keeping the cast on your keybind lets you choose the
  appropriate ability when your class has more than one dispel.
- In **Compact: removable names** mode, rows without a removable debuff are
  hidden while aura data is readable. If combat protection prevents a reliable
  check, the full roster stays visible so you can still select a target.
- Switch to **Names always shown** from `/pc mode` or the settings window.
- Shows a brief on-screen popup when the game-managed dispel slot appears. The
  popup can be disabled in settings; the alert sound has its own setting.
- Drag the title bar to move the window. Use `/pc lock` to toggle position
  locking.

## Commands

| Command | Action |
| --- | --- |
| `/pc config` | Open settings |
| `/pc show`, `/pc hide`, `/pc toggle` | Show or hide the window |
| `/pc lock` | Toggle position locking |
| `/pc sound` | Toggle the alert sound |
| `/pc combat` | Toggle hiding the window outside combat |
| `/pc mode` | Switch between afflicted-only and all-name display |
| `/pc reset` | Reset the window position |
| `/pc test` | Show a short test highlight |
| `/pc spells` | List detected dispel spells |
| `/pc version` | Show addon and game version details |
| `/pc debug`, `/pc why` | Print diagnostic information |

## Settings

The settings window controls visibility, position locking, out-of-combat
hiding, solo visibility, alert sound, highlight pulse, class-coloured names,
highlighting all typed debuffs, display mode, scale, and background opacity.
Changes to visibility and scale made during combat apply when combat ends.

PhantomCurse stores its options in the `PhantomCurseDB` SavedVariables table.
The client writes SavedVariables on logout or `/reload`.

## Compatibility

The addon uses the game's dispel-aware aura filtering and secure click buttons
to support combat lockdown. AuraContainer drives the game-drawn highlight;
readable aura data and an addon-drawn highlight provide fallback detection.
Use `/pc debug` or `/pc why` if the highlight does not appear as expected.
