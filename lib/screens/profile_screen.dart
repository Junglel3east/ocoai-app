// ─── Profile screen backdrop sizing ───────────────────────────────────────────
//
// Extended the hero crystal orb so it fills the background down toward the
// "App" section — less plain black between the Account block and App header.
//
// Height timeline: 300 → 354 (~18% bump) → 640 (~81% taller than 354) for a
// taller, more immersive vertical presence on tall phones (e.g. S23 Ultra).
// Uses BoxFit.contain + existing dark overlays in OracleProfileBackdrop so the
// asset stays crisp/HD with strong card/text contrast (no color wash).
//
// Position and layout are unchanged (ProfileScreen still in lib/main.dart).
// Only scale/height — no menu, card, or spacing edits.
//
// Shared with Account screen (_ProfileDetailScaffold showOracleBackdrop) for
// a consistent premium crystal-orb background across Profile + Account.

/// HD background orb height for Profile & Account (tall hero fill).
const double kProfileBackgroundOrbHeight = 640;

/// Slightly restrained opacity so a larger orb stays readable behind menus.
const double kProfileBackgroundOrbOpacity = 0.22;
