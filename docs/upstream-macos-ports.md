# macOS upstream ports (2026-10-09)

Reviewed upstream snapshot: `missuo/kumone` at `32b516c` (0.3.21).
No wholesale branch merge; the AppKit/TCA/APlay architecture stays intact.

- **CDN twin host failover (#115):** ported `NeteaseCDNHost` policy and its
  policy tests, adapted transport to APlay using `NeteaseCDNRetryProtocol`.
  Retries at most once before any HTTP response, preserves URL signature,
  request headers and Range. APlay keeps the original URL/cache identity and
  handles midstream reconnects. A failed host is avoided for ten minutes.
  Redirect responses prove reachability; errors from their targets do not
  poison the originating CDN. Sessions use weak delegate bridges and no
  additional URLCache. Source: upstream `5ee6815` / `4d3822a` and snapshot above.
- **Home placeholder width (#119, `ab2ee2b`):** added horizontal scroll
  containers around feature-card skeletons and skeleton shelves, without
  modifying populated card layout or Hero.
- **Custom/global shortcuts (#125):** ported the action/settings model and
  Carbon hotkey registration approach. Actions go through our existing
  dispatcher. Local overrides supersede the same action's YAML bindings;
  physical media keys and standard window/application shortcuts remain.
  Native menu key equivalents update immediately. Global bindings default
  to empty; Carbon registration failures do not overwrite the prior binding.
  Recording suspends global bindings temporarily, restores them on finish,
  and does not pass recorded keys to the local keymap. Keys can be cleared
  with Esc. No accessibility/event-tap permission is required.

No offline-download/AutoMix migration and no iOS entry-point changes.
The shared skeleton component necessarily also gains its width constraint.

Targeted acceptance command:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test -c release \
  --filter 'NeteaseCDNHostTests|NeteaseCDNRetryProtocolTests|ShortcutManagerTests|ShortcutIntegrationTests|GlobalHotKeyTests|CacheAwareStreamProviderTests|SettingsFeatureTests/testAllDisplaySettersPersistTheirValues'
```

Includes native Carbon event dispatch, registration conflict/cleanup, local
binding persistence and clear, editor/recorder protection, dynamic menu keys,
signed/ranged transport retry, bounded failure, redirect handling, cancellation
and completion deallocation. Cache-hit tests guard the existing buffer fix.

Result: Release build succeeded; 30 selected tests passed (19 TCA XCTest,
3 Mac integration XCTest, 8 CDN policy Swift Testing), with no skips/failures.
The real APlay stream delivers the whole file exactly once per playback,
stores it under the original host-dependent cache name, and reopens it without
any further network request. No deployment or app commit performed here.

The transport test exposed APlay 2.2.2 waiting on the bitmap at EOF for
block-aligned file lengths. A subsequent APlay 2.2.3 update fixes that boundary
and adds seven native EOF/lifecycle regression tests. The app now pins remote
2.2.3, and its real transport test requires both full-byte delivery and EOF on
the first download and the completed-cache replay.
