# PhantomCurse

A click-to-cleanse window for World of Warcraft: Forever. It lists your group
members and highlights debuffs your character can remove.

## Install

Copy the `PhantomCurse` folder into the game's `Interface\AddOns` folder. The
folder should contain `PhantomCurse.toc` and `PhantomCurse.lua` directly.
Restart the game or use `/reload`, then enable PhantomCurse in the AddOns list.

## Use

- Type `/pc` or `/phantomcurse` to see the available commands.
- Click a highlighted group member to cast a dispel on them.
- Left, right, and middle clicks plus Shift + left click can each use a
  different dispel spell when your class knows more than one.
- In **Names only when removable** mode, the addon shows players only while
  they have a debuff the game identifies as removable by your character.
  Active rows compact from the top of the window as debuffs appear and clear.
- Switch to **Names always shown** from `/pc mode` or the settings window.
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
| `/pc attach` | Toggle click-through empty rows when supported |

## Settings

The settings window controls visibility, position locking, out-of-combat
hiding, solo visibility, alert sound, highlight pulse, class-coloured names,
highlighting all typed debuffs, display mode, scale, and background opacity.
Changes to visibility and scale made during combat apply when combat ends.

PhantomCurse stores its options in the `PhantomCurseDB` SavedVariables table.
The client writes SavedVariables on logout or `/reload`.

## Compatibility

The addon uses the game's dispel-aware aura filtering and secure click buttons
to support combat lockdown. Some display and click-through behavior depends on
the client's `AuraContainer` and secure-frame support. Use `/pc debug` or
`/pc why` for diagnostics if the highlight or row stacking does not appear as
expected.
