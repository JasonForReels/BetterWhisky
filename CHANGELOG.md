# Changelog

What changed in each BetterWhisky release. Downloads are on the
[releases page](https://github.com/JasonForReels/BetterWhisky/releases).

BetterWhisky is a fork of [frankea/Whisky](https://github.com/frankea/Whisky). Changes from
before the fork, up to Whisky 3.10.2, are in [docs/WHISKY-CHANGELOG.md](docs/WHISKY-CHANGELOG.md).

## [1.4.1] - 2026-11-25

### Added
- **Update notifications.** When a new version is out while you're busy, BetterWhisky shows a
  macOS notification, like Software Update does, with an **Install** button. It never
  interrupts what you're doing. The red badge on the Dock icon and **Install Update…** in the
  menu are still there.

## [1.4.0] - 2026-11-25

### Added
- **Mod profiles, like a streaming service.** Make a profile, then add any mods to it: each
  profile is its own copy of the game, and every mod in it loads together, each with its own
  on/off switch. A new profile starts as a clean copy of the game.
- Profile tiles show the mod's logo (StellarRoles, Town of Us: Mira, LevelImposter), with a
  green **On** pill on the profile Play starts.
- **Play With**: the button beside Play on the Library banner, and **Play With** when you
  right-click a game, start whichever profile you pick.
- **Add Several Mods…**: tick known mods and pick files or folders, and they install one after
  another. **New Profile** can start with mods ticked.
- Mods can be added from a **whole folder** (like StellarRoles), as well as from GitHub, a
  `.zip` or a `.dll`. **From Files or Folders…** takes several at once.
- StellarRoles logo on its Library card and profile.

### Changed
- A new mod never replaces files another mod in the same profile put there.
- The compatibility check explains that shared text files, like `changelog.txt`, are
  harmless, and warns when two role mods (Town of Us, StellarRoles, The Other Roles…) share a
  profile, with how to undo it.
- The launch screen says when a mod's first start takes a few minutes.

### Fixed
- Mods that keep their own copy of the game's account save get yours before Play, so they no
  longer stop on the Privacy Policy ("I understand") screen.

## [1.3.0] - 2026-11-24

### Added
- **Steam Store** tab with trending games, top sellers and search, and a full-window game page
  with key art, details and screenshots.
- **Buy** opens Steam's own store page inside the app: it signs in first when needed, adds the
  game to the cart, and checkout stays on Steam's page. After the receipt, **Install** queues
  the game in the Steam bottle with no Wine window.
- Mod add-ons: companion apps that start with the game (BetterCrewLink), compatibility checks
  before an add-on goes in, and 7-Zip extraction, with BetterCrewLink and LevelImposter logos.

## [1.2.0] - 2026-11-24

### Added
- Mod profiles: several modded copies of one game, each with its own add-ons. Make one from an
  existing profile, rename it and switch between them.
- On/off switches for add-ons, which park their files instead of deleting them.

### Changed
- Add-on mods install into the modded copy's BepInEx plugins folder.

### Fixed
- Play signs in to Steam when needed instead of failing silently.

## [1.1.1] - 2026-11-23

### Changed
- DXMT is the recommended graphics backend, and modded copies of a game get its files too.

## [1.1.0] - 2026-11-23

### Added
- **Steam Library** tab: every game you own, from the Steam client, with install and uninstall.
- One-click Steam setup, which shows only Steam's sign-in.
- A game's recommended setup is applied after install and before Play.
- Steam Library Play asks which version (plain or modded) to start.

### Changed
- Top tab navigation: Library, Bottles and Search in the title bar.
- Bottle Configuration as category pages, a new-bottle sheet, and one grouped bottle screen
  with its actions in the toolbar.
- The game account is connected during mod setup, with a first-launch screen, by giving the
  mod a signed-in save instead of running the plain game.
- Winetricks installs use the bottle's sync mode.

## [1.0.0] - 2026-11-23

The first BetterWhisky release.

### Added
- **One-click mods from GitHub**: built-in presets (Town of Us: Mira, The Other Roles) or any
  GitHub repo. BetterWhisky reads the latest release and its install steps, installs the
  dependencies it needs, and shows the plan first. Dropping a `.zip` or `.dll` works too.
- Each mod gets a version-frozen copy of the game (an instant APFS clone) and its own Library
  card, and plays through Steam so you stay signed in.
- Mods update themselves when a release supports the current game.
- Faster modded starts: Steam warms up in the background and mod code is pre-compiled on your
  Mac. A loading screen shows each stage.
- Modded games use .NET's conserve-memory mode.
- Game page with artwork, Play and Mods.
- New app icon, the website, and BetterWhisky's own update feed, links and app ID.

### Fixed
- The command line tool looked for bottles in the old Whisky container.

[1.4.1]: https://github.com/JasonForReels/BetterWhisky/releases/tag/v1.4.1
[1.4.0]: https://github.com/JasonForReels/BetterWhisky/releases/tag/v1.4.0
[1.3.0]: https://github.com/JasonForReels/BetterWhisky/releases/tag/v1.3.0
[1.2.0]: https://github.com/JasonForReels/BetterWhisky/releases/tag/v1.2.0
[1.1.1]: https://github.com/JasonForReels/BetterWhisky/releases/tag/v1.1.1
[1.1.0]: https://github.com/JasonForReels/BetterWhisky/releases/tag/v1.1.0
[1.0.0]: https://github.com/JasonForReels/BetterWhisky/releases/tag/v1.0.0
